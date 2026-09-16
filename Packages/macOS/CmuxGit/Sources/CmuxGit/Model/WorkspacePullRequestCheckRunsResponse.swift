import Foundation

struct WorkspacePullRequestCheckRunsResponse: Decodable, Sendable {


    let totalCount: Int
    let checkRuns: [GitHubCheckRun]

    enum CodingKeys: String, CodingKey {
        case checkRuns = "check_runs"
        case totalCount = "total_count"
    }
}
