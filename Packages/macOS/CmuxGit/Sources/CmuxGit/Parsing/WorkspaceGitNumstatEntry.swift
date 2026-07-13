import Foundation

/// A normalized record from `git diff --numstat -z`.
struct WorkspaceGitNumstatEntry: Equatable, Sendable {
    let path: String
    let oldPath: String?
    let additions: Int
    let deletions: Int
    let binary: Bool
}
