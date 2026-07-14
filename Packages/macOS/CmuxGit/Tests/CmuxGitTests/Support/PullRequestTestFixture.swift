import Foundation
import Testing
@testable import CmuxGit

func pullRequestFixture(
    mergeable: String = "MERGEABLE",
    mergeStateStatus: String = "CLEAN",
    reviewDecision: String? = nil
) throws -> GitHubPullRequest {
    let data = try PullRequestFixtureLoader().data(named: "pull-request-view")
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object["mergeable"] = mergeable
    object["mergeStateStatus"] = mergeStateStatus
    object["reviewDecision"] = reviewDecision ?? NSNull()

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
        GitHubPullRequest.self,
        from: JSONSerialization.data(withJSONObject: object)
    )
}
