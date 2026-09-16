import Foundation

/// The subset of a GitHub pull-request detail response needed for the compact
/// sidebar status indicator.
struct WorkspacePullRequestDetailItem: Decodable, Sendable {


    let mergeable: Bool?
    let mergeableState: String?
    let head: GitHubPullRequestCommitRef?

    enum CodingKeys: String, CodingKey {
        case mergeable
        case mergeableState = "mergeable_state"
        case head
    }
}

