struct DiffReviewFileLoadRequest: Equatable {
    let path: String?
    let oldPath: String?
    let status: String?
    let attempt: Int
}
