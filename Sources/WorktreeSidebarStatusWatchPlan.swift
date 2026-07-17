import Foundation

/// Filesystem boundaries that can change one worktree row's Git status.
struct WorktreeSidebarStatusWatchPlan: Equatable, Sendable {
    static let empty = WorktreeSidebarStatusWatchPlan(recursivePaths: [], shallowPaths: [])

    let recursivePaths: [String]
    let shallowPaths: [String]
}
