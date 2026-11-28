import Foundation

/// A GitHub API response reduced to status code + body.
struct WorkspacePullRequestHTTPResponse: Sendable {
    let statusCode: Int
    let data: Data
}
