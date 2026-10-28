import CmuxNextCompat

/// The sidebar's rows and selection passes, each observed and also run on
/// demand. The window swaps a workspace's content in on a switch's own turn
/// (or its observation hop); the bridge reached `SidebarModel` a hop later and
/// the view drew it a hop after that, so the first frame of a new workspace
/// (Cmd-N) showed its content beside the old row selected and no new row. The
/// window runs `syncNow` before the swap: rows, selection and the drawn list
/// land in the same turn. A switch to a listed workspace runs only the
/// selection pass, which the list draws as a patch of the old and new rows. The streams' next values are then equal and skipped (the
/// model's setters, the selection hold, the view's render). The app's
/// SidebarBridge owns one.
@MainActor
public final class SidebarSameTurn {
    private let view: SidebarView
    private var passes: [(listsRows: Bool, run: @MainActor () -> Void)] = []
    private var tasks: [Task<Void, Never>] = []

    public init(view: SidebarView) {
        self.view = view
    }

    /// Observes `compute`, handing each value to `apply`; `syncNow` runs it too. `listsRows`
    /// marks the rows pass, which walks every workspace.
    public func observe<Value: Sendable>(listsRows: Bool = false, _ compute: @escaping @MainActor @Sendable () -> Value,
                                  apply: @escaping @MainActor @Sendable (Value) -> Void) {
        passes.append((listsRows, { apply(compute()) }))
        // A trigger: `syncNow` applies outside the stream too, and `apply` compares with what it applied.
        tasks.append(Task { for await value in ObservationStream({ ObservationTrigger(compute()) }) { apply(value.value) } })
    }

    /// Runs the passes in order (rows, then selection) and draws the sidebar now. `rows` false
    /// skips the rows pass: a workspace shown before is listed already, and a switch to it
    /// should not pay a walk of every workspace.
    public func syncNow(rows: Bool) {
        for pass in passes where rows || !pass.listsRows { pass.run() }
        view.renderNow()
    }

    /// Refreshes the rows through their normal projection before an action
    /// resolves a slot. The action can then place its row before rendering.
    public func syncRows() {
        for pass in passes where pass.listsRows { pass.run() }
    }

    public func cancel() {
        for task in tasks { task.cancel() }
    }
}
