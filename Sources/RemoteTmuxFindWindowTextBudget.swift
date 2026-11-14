import Foundation

/// The pane text one opening of find-window may hold, shared by every pane it reads.
///
/// Readers take bytes as each chunk arrives, so panes read in parallel on different
/// hosts cannot each spend the whole remainder.
@MainActor
final class RemoteTmuxFindWindowTextBudget {
    private(set) var remaining: Int

    init(bytes: Int) {
        remaining = max(0, bytes)
    }

    /// Takes `count` bytes if they fit; returns false and takes nothing otherwise.
    func take(_ count: Int) -> Bool {
        guard count <= remaining else { return false }
        remaining -= count
        return true
    }
}
