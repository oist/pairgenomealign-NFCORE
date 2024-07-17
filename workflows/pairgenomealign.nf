/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

include { ASSEMBLYSCAN           } from '../modules/nf-core/assemblyscan/main'
include { CUSTOMMODULE           } from '../modules/local/custommodule'
include { PAIRALIGN_M2M          } from '../subworkflows/local/pairalign_m2m/main'
include { SEQTK_CUTN as SEQTK_CUTN_TARGET  } from '../modules/nf-core/seqtk/cutn/main'
include { SEQTK_CUTN as SEQTK_CUTN_QUERY  } from '../modules/nf-core/seqtk/cutn/main'
include { PAIRALIGN_M2O          } from '../subworkflows/local/pairalign_m2o/main'
include { MULTIQC                } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMap       } from 'plugin/nf-validation'
include { paramsSummaryMultiqc   } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText } from '../subworkflows/local/utils_nfcore_pairgenomealign_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PAIRGENOMEALIGN {

    take:
    ch_samplesheet  // channel: samplesheet read in from --input
    ch_targetgenome // channel: genome file read in from --target

    main:

    ch_versions = Channel.empty()
    ch_multiqc_files = Channel.empty()

    //
    // MODULE: seqtk_cutn_target
    //
    SEQTK_CUTN_TARGET (
        // Avoid file name conflicts when target genome is also in the list of queries
        ch_targetgenome.map { meta, file -> [ [id:'targetGenome'] , file ] }
    )

    //
    // MODULE: seqtk_cutn_query
    //
    SEQTK_CUTN_QUERY (
        ch_samplesheet
    )

    //
    // MODULE: assembly-scan
    //
    ASSEMBLYSCAN (
        ch_samplesheet
    )

    //
    // MODULE: custommodule
    //
    CUSTOMMODULE (
        ASSEMBLYSCAN.out.json.collect{it[1]}
    )

    // Prefix query ids with target genome name before producing alignment files
    ch_samplesheet = ch_samplesheet
        .map { row -> [ [id: params.targetName + '___' + row[0].id] , row.tail() ] }
    ch_seqtk_cutn_query = SEQTK_CUTN_QUERY.out.bed
        .map { row -> [ [id: params.targetName + '___' + row[0].id] , row.tail() ] }

    //
    // SUBWORKFLOW: pairalign_m2o
    //
    if (!(params.m2m)) {
    PAIRALIGN_M2O (
        ch_targetgenome,
        ch_samplesheet,
        SEQTK_CUTN_TARGET.out.bed,
        ch_seqtk_cutn_query
    )
    pairalign_out = PAIRALIGN_M2O.out
    } else {

    //
    // SUBWORKFLOW: pairalign_m2m
    //
    PAIRALIGN_M2M (
        ch_targetgenome,
        ch_samplesheet,
        SEQTK_CUTN_TARGET.out.bed,
        ch_seqtk_cutn_query
    )
    pairalign_out = PAIRALIGN_M2M.out
    }

    // Collate and save software versions
    //

    ch_versions = ch_versions
        .mix(SEQTK_CUTN_TARGET.out.versions)
        .mix(     ASSEMBLYSCAN.out.versions)
        .mix(        pairalign_out.versions)

    softwareVersionsToYAML(ch_versions)
        .collectFile(
            storeDir: "${params.outdir}/pipeline_info",
            name: 'nf_core_pipeline_software_mqc_versions.yml',
            sort: true,
            newLine: true
        ).set { ch_collated_versions }

    //
    // MODULE: MultiQC
    //
    ch_multiqc_config        = Channel.fromPath(
        "$projectDir/assets/multiqc_config.yml", checkIfExists: true)
    ch_multiqc_custom_config = params.multiqc_config ?
        Channel.fromPath(params.multiqc_config, checkIfExists: true) :
        Channel.empty()
    ch_multiqc_logo          = params.multiqc_logo ?
        Channel.fromPath(params.multiqc_logo, checkIfExists: true) :
        Channel.empty()

    summary_params      = paramsSummaryMap(
        workflow, parameters_schema: "nextflow_schema.json")
    ch_workflow_summary = Channel.value(paramsSummaryMultiqc(summary_params))

    ch_multiqc_custom_methods_description = params.multiqc_methods_description ?
        file(params.multiqc_methods_description, checkIfExists: true) :
        file("$projectDir/assets/methods_description_template.yml", checkIfExists: true)
    ch_methods_description                = Channel.value(
        methodsDescriptionText(ch_multiqc_custom_methods_description))

    ch_multiqc_files = ch_multiqc_files
        .mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
        .mix(CUSTOMMODULE.out.tsv)
        .mix(pairalign_out.multiqc)
        .mix(ch_collated_versions)
        .mix(
        ch_methods_description.collectFile(
            name: 'methods_description_mqc.yaml',
            sort: true
        )
    )

    MULTIQC (
        ch_multiqc_files.collect(),
        ch_multiqc_config.toList(),
        ch_multiqc_custom_config.toList(),
        ch_multiqc_logo.toList(),
        [],
        []
    )

    emit:
    multiqc_report = MULTIQC.out.report.toList() // channel: /path/to/multiqc_report.html
    versions       = ch_versions                 // channel: [ path(versions.yml) ]
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
