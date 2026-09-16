import Foundation

/// The subset of a GitHub pull-request detail response needed for the compact
/// sidebar status indicator.
struct WorkspacePullRequestDetailItem: Decodable, Sendable {
    struct Ref: Decodable, Sendable {
        let sha: String?
    }

    let mergeable: Bool?
    let mergeableState: String?
    let head: Ref?

    enum CodingKeys: String, CodingKey {
        case mergeable
        case mergeableState = "mergeable_state"
        case head
    }
}

