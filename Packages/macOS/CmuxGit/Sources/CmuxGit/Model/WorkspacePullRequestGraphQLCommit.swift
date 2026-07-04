import Foundation

struct WorkspacePullRequestGraphQLCommit: Decodable, Sendable {
    let statusCheckRollup: WorkspacePullRequestGraphQLStatusCheckRollup?
}
