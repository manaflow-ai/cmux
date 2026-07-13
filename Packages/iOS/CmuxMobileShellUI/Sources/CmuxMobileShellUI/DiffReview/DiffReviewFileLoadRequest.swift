import CmuxDiffModel

struct DiffReviewFileLoadRequest: Equatable {
    let path: String?
    let oldPath: String?
    let status: DiffFileStatus?
    let attempt: Int
}
