import Foundation

/// GitHub REST `pulls` payload item, decoded snake_case and mapped to
/// ``GitHubPullRequestProbeItem``.
struct WorkspacePullRequestRESTItem: Decodable, Sendable {
    struct Ref: Decodable, Sendable {
        let ref: String
    }

    let number: Int
    let state: String
    let htmlURL: String
    let updatedAt: String?
    let mergedAt: String?
    let head: Ref
    let base: Ref?

    enum CodingKeys: String, CodingKey {
        case number
        case state
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
        case mergedAt = "merged_at"
        case head
        case base
    }
}
