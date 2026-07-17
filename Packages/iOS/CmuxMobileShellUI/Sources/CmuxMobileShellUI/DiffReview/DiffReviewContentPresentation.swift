import CmuxDiffModel

struct DiffReviewContentPresentation {
    let rename: DiffReviewRenamePresentation?
    let metadataLines: [String]

    init(file: DiffFileSummary?, hunks: [DiffHunk], metadataLines: [String]) {
        rename = file.flatMap(DiffReviewRenamePresentation.init(file:))
        self.metadataLines = metadataLines
    }
}
