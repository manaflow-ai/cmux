import Foundation

struct WorkspacePullRequestGraphQLRequestBody: Encodable, Sendable {
    let query: String
    let variables: WorkspacePullRequestGraphQLVariables
}
