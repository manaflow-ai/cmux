import CmuxNextCompat
import CmuxNextSidebar

/// The sidebar's rows and selection passes, each observed and also run on
/// demand. The window swaps a workspace's content in on its own observation
/// hop; the bridge reached `SidebarModel` a hop later and the view drew it a
/// hop after that, so the first frame of a new workspace (Cmd-N) showed its
/// content beside the old row selected and no new row. The window runs
/// `syncNow` before the swap: rows, selection and the drawn list land in the
/// same turn. The streams' next values are then equal and skipped (the
/// model's setters, the selection hold, the view's render). A helper beside
/// SidebarBridge (its type is at its size limit).
@MainActor
final class SidebarSameTurn {
    private let view: SidebarView
    private var passes: [@MainActor () -> Void] = []
    private var tasks: [Task<Void, Never>] = []

    init(view: SidebarView) {
        self.view = view
    }

    /// Observes `compute`, handing each value to `apply`; `syncNow` runs it too.
    func observe<Value: Sendable>(_ compute: @escaping @MainActor @Sendable () -> Value,
                                  apply: @escaping @MainActor @Sendable (Value) -> Void) {
        passes.append { apply(compute()) }
        tasks.append(Task { for await value in ObservationStream(compute) { apply(value) } })
    }

    /// Runs every pass in order (rows, then selection) and draws the sidebar now.
    func syncNow() {
        for pass in passes { pass() }
        view.renderNow()
    }

    func cancel() {
        for task in tasks { task.cancel() }
    }
}
