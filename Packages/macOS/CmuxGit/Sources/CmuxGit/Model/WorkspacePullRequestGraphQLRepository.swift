import Foundation

struct WorkspacePullRequestGraphQLRepository: Decodable, Sendable {
    let pullRequests: WorkspacePullRequestGraphQLPullRequestConnection
}
