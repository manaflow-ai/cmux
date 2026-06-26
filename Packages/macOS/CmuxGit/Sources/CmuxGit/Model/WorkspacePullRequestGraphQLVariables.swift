import Foundation

struct WorkspacePullRequestGraphQLVariables: Encodable, Sendable {
    let owner: String
    let name: String
    let first: Int
}
