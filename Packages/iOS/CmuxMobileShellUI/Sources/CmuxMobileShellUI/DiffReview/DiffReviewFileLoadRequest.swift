import CmuxDiffModel

struct DiffReviewFileLoadRequest: Equatable {
    let file: DiffFileSummary?
    let attempt: Int
}
