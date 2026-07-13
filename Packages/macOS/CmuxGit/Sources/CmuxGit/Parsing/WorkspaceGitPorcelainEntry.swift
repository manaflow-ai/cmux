import Foundation

/// A normalized record from `git status --porcelain=v1 -z`.
struct WorkspaceGitPorcelainEntry: Equatable, Sendable {
    let path: String
    let oldPath: String?
    let status: String
    let untracked: Bool
}
