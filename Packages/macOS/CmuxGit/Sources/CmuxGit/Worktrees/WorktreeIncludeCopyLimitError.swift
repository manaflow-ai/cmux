import Foundation

/// Indicates that actual worktree copy output exceeded its aggregate budget.
struct WorktreeIncludeCopyLimitError: LocalizedError, Sendable {
    let itemCount: Int
    let byteCount: Int64

    var errorDescription: String? {
        "The .worktreeinclude copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
    }
}
