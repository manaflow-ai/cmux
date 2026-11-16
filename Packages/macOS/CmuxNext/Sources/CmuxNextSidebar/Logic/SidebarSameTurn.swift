import CmuxNextCompat

/// The sidebar's rows and selection passes, each observed and also run on
/// demand. The window swaps a workspace's content in on a switch's own turn
/// (or its observation hop); the bridge reached `SidebarModel` a hop later and
/// the view drew it a hop after that, so the first frame of a new workspace
/// (Cmd-N) showed its content beside the old row selected and no new row. The
/// window runs `syncNow` before the swap: rows, selection and the drawn list
/// land in the same turn. A switch to a listed workspace runs only the
/// selection pass, which the list draws as a patch of the old and new rows. The app's
/// SidebarBridge owns one.
///
/// Each pass has one observation and runs once for a change. `syncNow` runs in the turn of the change,
/// after the write that fired the pass's observation: its run is the tracked one, and it reads the new
/// values, so the pass's own hop finds nothing changed and computes nothing. Before, the hop of the same
/// change ran every pass a second time (for a space switch, a second walk of every row of the space and
/// a second fill of the rows feed, ahead of the commit that shows the switch).
@MainActor
public final class SidebarSameTurn {
    /// What one pass's observation tells its task: a value the pass read is about to change. Not main-actor
    /// isolated: the will-set callback marks it from inside the write.
    nonisolated private final class Change: Sendable {
        /// Set by the will-set callback (inside the write); cleared by the run that reads the new values.
        private let stale = Atomic<Bool>(true)
        let wakes: AsyncStream<Void>
        private let wake: AsyncStream<Void>.Continuation

        init() {
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            wakes = stream
            wake = continuation
            continuation.yield(()) // the pass's first run
        }

        /// A value the pass read is about to change: its task runs the pass after the write.
        func mark() {
            stale.store(true, ordering: .releasing)
            wake.yield(())
        }

        /// The run that starts now reads the values as they are.
        func clear() { stale.store(false, ordering: .releasing) }

        /// Whether a value changed since the last run (asked once: the next answer is false).
        func take() -> Bool { stale.exchange(false, ordering: .acquiringAndReleasing) }

        func finish() { wake.finish() }
    }

    private let view: SidebarView
    private var passes: [(listsRows: Bool, run: @MainActor () -> Void)] = []
    private var changes: [Change] = []
    private var tasks: [Task<Void, Never>] = []

    public init(view: SidebarView) {
        self.view = view
    }

    /// Observes `compute`, handing each value to `apply`; `syncNow` runs it too. `listsRows`
    /// marks the rows pass, which walks every workspace.
    public func observe<Value: Sendable>(listsRows: Bool = false, _ compute: @escaping @MainActor @Sendable () -> Value,
                                  apply: @escaping @MainActor @Sendable (Value) -> Void,
                                  fileID: StaticString = #fileID, line: UInt = #line) {
        // One registration armed at a time: a run while it has not fired reads what the last run read, untracked.
        let tracking = SingleArmedTracking(), change = Change()
        let run: @MainActor @Sendable () -> Void = {
            change.clear()
            // Every run applies: `apply` compares with what it applied.
            apply(tracking.track(shape: [], { compute() }, onChange: { change.mark() }, fileID: fileID, line: line))
        }
        passes.append((listsRows, run))
        changes.append(change)
        // task-owner: the pass's runs after a change; ends with `cancel()` (the bridge's teardown)
        tasks.append(Task {
            for await _ in change.wakes {
                // A run since the change (`syncNow`, in the turn of the change) read the new values already.
                if change.take() { run() }
            }
        })
    }

    /// Runs the passes in order (rows, then selection) and draws the sidebar now. `rows` false
    /// skips the rows pass: a workspace shown before is listed already, and a switch to it
    /// should not pay a walk of every workspace.
    public func syncNow(rows: Bool) {
        for pass in passes where rows || !pass.listsRows { pass.run() }
        view.renderNow()
    }

    /// Whether the sidebar still lists another space than `space`, the window's: the space changed in this
    /// turn (a space switch, or a workspace of another space shown by id), so the rows pass must run with the
    /// content swap. A workspace the window kept mounted ran no rows pass and drew beside the old space's rows.
    public func listsAnotherSpace(than space: String) -> Bool {
        view.model.activeProfileID.map { $0.rawValue != space } ?? false
    }

    /// Runs `show`, the window's content swap for a space switch, then the rows pass if the sidebar still lists
    /// another space than `space`: a switch that swaps no content (an empty space waits for its first workspace,
    /// a page or a waiting machine keeps what is shown) ran no pass, and the sidebar listed the space the window
    /// left until an observation hop. A swap that ran the pass leaves nothing to do here.
    public func showing(space: @autoclosure () -> String, _ show: () -> Void) {
        show()
        if listsAnotherSpace(than: space()) { syncNow(rows: true) }
    }

    public func cancel() {
        for task in tasks { task.cancel() }
        for change in changes { change.finish() }
    }
}
