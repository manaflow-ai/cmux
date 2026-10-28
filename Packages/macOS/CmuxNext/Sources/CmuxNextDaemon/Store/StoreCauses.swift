import CmuxNextWakeups

/// The daemon store's side of the app's ``ObservationCauses``
/// (plans/cmux-next/chrome-parity/p06-scheduler.md section D). Each change applies with the cause of
/// whoever made it: a daemon event with its envelope's cause, a local intent with the cause of the
/// action run that made it. What the store publishes later than the change (the sidebar
/// flattening, the tab list, the workspace set, a resync's snapshot) publishes with the highest
/// cause of the changes that asked for it, never with that of whatever else its batch applied, as
/// Chrome posts a task with the priority of what asked for it (`base/task/task_traits.h`).
///
/// The cause is for scheduling only. Authorization code never reads it.
@MainActor
final class StoreCauses {
    /// The batches that asked for the next snapshot: it applies with this cause. Kept for a retry
    /// of a failed one only; a later event-triggered resync takes the cause of its own batch.
    var resync: ObservationCause = .program
    /// The changes that need the next sidebar flattening; nil when none does.
    private(set) var sidebar: ObservationCause?
    /// The changes of the tab list since its last publish; nil when none was recorded.
    private var tabList: ObservationCause?
    /// The sidebar flattenings since the workspace set was last checked; nil when none ran.
    private var workspaceSet: ObservationCause?
    /// The app's causes (`MainWorkScheduler.causes`); nil (tests, fixtures): every change is program.
    private let scope: ObservationCauses?

    init(_ scope: ObservationCauses?) {
        self.scope = scope
    }

    /// The cause of the changes made now: ``ObservationCause/program`` outside every scope.
    var current: ObservationCause { scope?.currentCause ?? .program }

    /// Runs `body` with `cause` as the current cause, then restores the cause it had.
    @discardableResult
    func with<T>(_ cause: ObservationCause, _ body: () -> T) -> T {
        guard let scope else { return body() }
        return scope.withCause(cause) { body() }
    }

    /// Records that the current change needs a sidebar flattening (true), or that it ran (false).
    func noteSidebar(_ needed: Bool) {
        sidebar = needed ? max(sidebar ?? current, current) : nil
    }

    /// Records that a change made with `cause` changed the tab list.
    func noteTabList(_ cause: ObservationCause) {
        tabList = max(tabList ?? cause, cause)
    }

    /// The cause the tab list publishes with (the current one when no change was recorded); resets it.
    func takeTabList() -> ObservationCause {
        defer { tabList = nil }
        return tabList ?? current
    }

    /// Records a sidebar flattening made now: the workspace set may have changed.
    func noteFlattening() {
        workspaceSet = max(workspaceSet ?? current, current)
    }

    /// The cause a change of the workspace set publishes with; resets it.
    func takeWorkspaceSet() -> ObservationCause {
        defer { workspaceSet = nil }
        return workspaceSet ?? current
    }
}
