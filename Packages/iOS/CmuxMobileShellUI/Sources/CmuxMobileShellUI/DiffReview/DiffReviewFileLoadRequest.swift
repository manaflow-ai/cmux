struct DiffReviewFileLoadRequest: Equatable {
    let path: String?
    let oldPath: String?
    let attempt: Int
}
