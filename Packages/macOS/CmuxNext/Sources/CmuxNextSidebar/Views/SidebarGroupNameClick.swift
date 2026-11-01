import AppKit
import CmuxNextWakeups

/// A click on a group header's name folds the group once the double-click interval has passed:
/// a second click in that time renames the group in place (`SidebarInlineRename`), and a fold in
/// between would move every row under the header (user 2026-10-31: "double click to rename
/// workspaces must not have layout shift. should also work for renaming groups too"). A click
/// anywhere else on the bar still folds at once, every click (cx-q5jw).
@MainActor final class SidebarGroupNameClick {
    /// How long a click on the name waits for a second click.
    private let delay: Duration
    private let timer: DemandTimer
    private var pending: (group: GroupID, fold: @MainActor () -> Void)?

    init(delay: Duration = .seconds(NSEvent.doubleClickInterval), clock: any Clock<Duration> = ContinuousClock()) {
        self.delay = delay
        timer = DemandTimer(owner: "sidebar.groupNameClick", clock: clock)
    }

    /// A fold waits for a second click.
    var isWaiting: Bool { pending != nil }

    /// Runs `fold` for `group` after the double-click interval unless a second click takes it first.
    func schedule(_ group: GroupID, fold: @escaping @MainActor () -> Void) {
        flush()
        pending = (group, fold)
        timer.schedule(after: delay) { @MainActor [weak self] in self?.flush() }
    }

    /// Drops `group`'s waiting fold (its double-click renames instead); false when none waits.
    func take(_ group: GroupID) -> Bool {
        guard let pending, pending.group == group else { return false }
        timer.cancel()
        self.pending = nil
        return true
    }

    /// Folds the waiting group now: the interval ended, or another press came first.
    func flush() {
        guard let pending else { return }
        timer.cancel()
        self.pending = nil
        pending.fold()
    }
}
