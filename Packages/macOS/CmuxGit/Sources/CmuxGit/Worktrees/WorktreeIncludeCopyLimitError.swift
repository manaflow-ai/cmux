import Foundation

/// Indicates that actual worktree copy output exceeded its aggregate budget.
struct WorktreeIncludeCopyLimitError: LocalizedError, Sendable {
    enum Reason: Sendable {
        case resourceLimit
        case capacity
    }

    let itemCount: Int
    let byteCount: Int64
    let reason: Reason

    var errorDescription: String? {
        switch reason {
        case .resourceLimit:
            "The .worktreeinclude copy limit was exceeded (\(itemCount) items or \(byteCount) bytes)."
        case .capacity:
            "Skipped .worktreeinclude copy because the destination volume lacks sufficient free space."
        }
    }
}
