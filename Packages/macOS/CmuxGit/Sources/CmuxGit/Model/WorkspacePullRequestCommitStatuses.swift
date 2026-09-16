import Foundation

/// Latest legacy status per context, returned by the combined status endpoint.
struct WorkspacePullRequestCommitStatuses: Decodable, Sendable {


    let totalCount: Int
    let statuses: [GitHubCommitStatus]

    enum CodingKeys: String, CodingKey {
        case statuses
        case totalCount = "total_count"
    }
}
