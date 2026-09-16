import Foundation

/// Latest legacy status per context, returned by the combined status endpoint.
struct WorkspacePullRequestCommitStatuses: Decodable, Sendable {
    struct Status: Decodable, Sendable {
        let id: Int
        let context: String
        let state: String
        let targetURL: String?

        enum CodingKeys: String, CodingKey {
            case id, context, state
            case targetURL = "target_url"
        }
    }

    let totalCount: Int
    let statuses: [Status]

    enum CodingKeys: String, CodingKey {
        case statuses
        case totalCount = "total_count"
    }
}
