import CmuxNextCompat
public import CmuxNextWakeups

/// The sidebar's rows and selection passes, each observed and also run on
/// demand. The window swaps a workspace's content in on a switch's own turn
/// (or its observation hop); the bridge reached `SidebarModel` a hop later and
/// the view drew it a hop after that, so the first frame of a new workspace
/// (Cmd-N) showed its content beside the old row selected and no new row. The
/// window runs `syncNow` before the swap: rows, selection and the drawn list
/// land in the same turn. A switch to a listed workspace runs only the
/// selection pass, which the list draws as a patch of the old and new rows. The observations' next values are then equal and skipped (the
/// model's setters, the selection hold, the view's render). The app's
/// SidebarBridge owns one.
///
/// Each pass is a ``ServiceObservation`` (its apply writes the sidebar's model, so it runs while the window is hidden
/// too): a person's change applies in the input-response pass, before the commit of their input, and any other in one
/// posted `visible` task per burst (Chrome's posted UI-thread task with a TaskPriority, base/task/task_traits.h).
@MainActor
public final class SidebarSameTurn {
    private let view: SidebarView
    private let mainWork: MainWorkScheduler
    private var passes: [(listsRows: Bool, run: @MainActor () -> Void)] = []
    /// Each pass's observation, held by its cancel.
    private var stops: [@MainActor () -> Void] = []

    /// - Parameters:
    ///   - view: The sidebar `syncNow` draws.
    ///   - mainWork: The app's one main-thread scheduler (`AppServices.mainWork`): the passes' flushes are posted on it.
    public init(view: SidebarView, mainWork: MainWorkScheduler) {
        self.view = view
        self.mainWork = mainWork
    }

    /// Observes `compute`, handing each value to `apply` (the current one before it returns); `syncNow` runs it too.
    /// `listsRows` marks the rows pass, which walks every workspace.
    public func observe<Value: Sendable>(listsRows: Bool = false, _ compute: @escaping @MainActor @Sendable () -> Value,
                                  apply: @escaping @MainActor @Sendable (Value) -> Void) {
        passes.append((listsRows, { apply(compute()) }))
        // A trigger: `syncNow` applies outside the observation too, and `apply` compares with what it applied.
        let owner = listsRows ? "Sidebar.rowsPass" : "Sidebar.selectionPass"
        let observation = ServiceObservation(.visible, owner: owner, on: mainWork) { ObservationTrigger(compute()) } apply: { trigger in
            apply(trigger.value)
        }
        stops.append { observation.cancel() }
    }

    /// Runs the passes in order (rows, then selection) and draws the sidebar now. `rows` false
    /// skips the rows pass: a workspace shown before is listed already, and a switch to it
    /// should not pay a walk of every workspace.
    public func syncNow(rows: Bool) {
        for pass in passes where rows || !pass.listsRows { pass.run() }
        view.renderNow()
    }

    public func cancel() {
        for stop in stops { stop() }
        stops = []
    }
}
