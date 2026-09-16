import Foundation

struct WorkspacePullRequestCheckRunsResponse: Decodable, Sendable {
    struct CheckRun: Decodable, Sendable {
        let id: Int
        let name: String
        let status: String
        let conclusion: String?
        let detailsURL: String?

        enum CodingKeys: String, CodingKey {
            case id
            case name
            case status
            case conclusion
            case detailsURL = "details_url"
        }
    }

    let totalCount: Int
    let checkRuns: [CheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
        case totalCount = "total_count"
    }
}
