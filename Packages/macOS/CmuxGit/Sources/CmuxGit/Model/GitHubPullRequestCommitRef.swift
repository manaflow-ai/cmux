import Foundation

struct GitHubPullRequestCommitRef: Decodable, Sendable {
    let sha: String?
}
