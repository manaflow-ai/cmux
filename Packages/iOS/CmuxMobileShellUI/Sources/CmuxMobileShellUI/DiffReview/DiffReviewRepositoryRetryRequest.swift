import CmuxDiffModel

struct DiffReviewRepositoryRetryRequest: Equatable {
    let path: String
    let oldPath: String?
    let status: DiffFileStatus
    let manualAttempt: Int

    static let unspecified = Self(
        path: "",
        oldPath: nil,
        status: .modified,
        manualAttempt: 0
    )
}
