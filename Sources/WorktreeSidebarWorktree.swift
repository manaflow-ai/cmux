import Foundation

/// One record reported by `git worktree list --porcelain`.
struct WorktreeSidebarWorktree: Identifiable, Equatable, Sendable {
    let path: String
    let head: String?
    let branchRef: String?
    let isDetached: Bool
    let isBare: Bool
    let isMain: Bool
    let isLocked: Bool
    let lockReason: String?
    let isPrunable: Bool
    let prunableReason: String?

    var id: String { path }

    var name: String {
        let name = URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
        return name.isEmpty ? path : name
    }

    var branchName: String? {
        guard let branchRef else { return nil }
        let prefix = "refs/heads/"
        return branchRef.hasPrefix(prefix)
            ? String(branchRef.dropFirst(prefix.count))
            : branchRef
    }
}
