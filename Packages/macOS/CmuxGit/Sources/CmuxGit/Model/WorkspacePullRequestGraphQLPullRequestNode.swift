import Foundation

struct WorkspacePullRequestGraphQLPullRequestNode: Decodable, Sendable {
    let number: Int
    let headRefName: String?
    let commits: WorkspacePullRequestGraphQLCommitConnection?

    var ciStatus: PullRequestCheckStatus {
        let state = commits?.nodes?.compactMap { $0?.commit.statusCheckRollup?.state }.last
        return PullRequestCheckStatus(githubStatusCheckRollupState: state)
    }
}
