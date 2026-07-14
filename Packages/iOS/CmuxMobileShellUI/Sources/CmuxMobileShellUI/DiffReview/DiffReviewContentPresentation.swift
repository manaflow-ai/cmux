import CmuxDiffModel

struct DiffReviewContentPresentation {
    let rename: DiffReviewRenamePresentation?
    let metadataLines: [String]

    init(file: DiffFileSummary?, hunks: [DiffHunk], metadataLines: [String]) {
        rename = hunks.isEmpty ? file.flatMap(DiffReviewRenamePresentation.init(file:)) : nil
        self.metadataLines = metadataLines
    }
}
