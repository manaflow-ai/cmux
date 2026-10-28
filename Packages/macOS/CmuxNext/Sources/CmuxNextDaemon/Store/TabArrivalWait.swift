public import CmuxNextWakeups

/// One wait for a tab to arrive in a ``DaemonStore`` by its lasting id (`TabModel.id` or its `tab_`
/// resource id), bounded: a person's action that names a tab the tree does not have yet (a banner
/// click that launched the app, before the daemon's first snapshot). `then` runs once: with the
/// tab's surface when it arrives, or with nil at the deadline. No poll: a ``ServiceObservation`` on
/// the store's tab list and one ``MainDeadline``. The owner keeps the wait; releasing it before
/// it ends cancels both.
@MainActor
public final class TabArrivalWait {
    private let deadline: MainDeadline
    private var arrivals: ServiceObservation<SurfaceID?>?
    private var then: (@MainActor (SurfaceID?) -> Void)?

    /// Starts waiting; `then` runs at once (in this turn) when the tab is already in `store`.
    ///
    /// - Parameters:
    ///   - tab: The tab's lasting id or tab resource id.
    ///   - within: How long it waits before `then(nil)`.
    ///   - workClass: The class of the arrival's flush (`visible` for a person's click).
    public init(tab: String, in store: DaemonStore, within: Duration, owner: String, workClass: BudgetedWorkClass,
                work: MainWorkScheduler, deadlines: MainDeadlineScheduler, then: @escaping @MainActor (SurfaceID?) -> Void) {
        deadline = MainDeadline(owner: owner, workClass: workClass, scheduler: deadlines)
        self.then = then
        if let found = store.tab(idOrResource: tab) {
            finish(found.surface)
            return
        }
        deadline.schedule(after: within) { [weak self] in self?.finish(nil) }
        arrivals = ServiceObservation(workClass, owner: owner + ".arrivals", on: work) {
            store.tab(idOrResource: tab)?.surface
        } apply: { [weak self] surface in
            if let surface { self?.finish(surface) }
        }
    }

    /// The wait ended (`then` ran).
    public var isDone: Bool { then == nil }

    private func finish(_ surface: SurfaceID?) {
        guard let then else { return }
        self.then = nil
        deadline.cancel()
        arrivals = nil
        then(surface)
    }
}
