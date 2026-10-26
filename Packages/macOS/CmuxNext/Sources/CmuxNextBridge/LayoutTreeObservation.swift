public import CmuxNextDaemon
public import CmuxNextWakeups
import Observation

/// Follows one workspace's layout mapping and hands each new mapping to its owner with the cause
/// of the changes that made it (p06-scheduler-038): the App's workspace content applies it with
/// that cause, so the layout tells an agent's burst of splits from a person's split
/// (`LayoutAutomationBurst`).
///
/// The tracking and coalescing are `VisibleObservation`'s, with no node: the apply must run while
/// the workspace is hidden too (an off-screen workspace still takes its handles, which commands
/// translate through, and keeps the latest tree for its show).
/// 1. ``start()`` reads the mapping with tracking, for the owner's first-frame apply.
/// 2. The first change of what it read records ``ObservationCauses/currentCause`` at Observation's
///    will-set, in the turn of the change (the daemon store's drain sets it per envelope, an
///    action run per origin). Until the cause is person, the tracking is armed again in that turn
///    (one read), so a later change before the apply raises it.
/// 3. The apply is one task posted on the scheduler in the class of the cause: `automation` for an
///    agent's, the CLI's or another process's change, `visible` for the rest. A raised cause in
///    another class posts its own task; the stale one finds nothing to do.
///
/// ```swift
/// observation = LayoutTreeObservation(workspace, on: services.mainWork) { [weak self] result, cause in
///     self?.apply(result, cause: cause)
/// }
/// apply(observation.start(), cause: services.mainWork.causes.currentCause)
/// ```
@MainActor
public final class LayoutTreeObservation {
    private let workspace: WorkspaceModel
    private let work: MainWorkScheduler
    private let owner: MainTaskOwner
    private let apply: @MainActor (LayoutMapping.Result, ObservationCause) -> Void
    /// The highest cause of the changes since the last apply; nil while none is pending.
    private var pending: ObservationCause?
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    private var cancelled = false

    /// - Parameters:
    ///   - workspace: The workspace whose mapping it follows.
    ///   - work: The app's main-thread scheduler: its causes name each change's cause, and the
    ///     apply runs as its task.
    ///   - apply: Applies a new mapping with the cause of its changes.
    public init(_ workspace: WorkspaceModel, on work: MainWorkScheduler,
                apply: @escaping @MainActor (LayoutMapping.Result, ObservationCause) -> Void) {
        self.workspace = workspace
        self.work = work
        owner = work.board.owner("WorkspaceLayout")
        self.apply = apply
    }

    /// The mapping now, tracked: the owner's first-frame apply. Later changes go to `apply`.
    public func start() -> LayoutMapping.Result {
        track()
    }

    /// No later apply. An armed tracking fires once more at the next change and does nothing.
    public func cancel() {
        cancelled = true
        generation &+= 1
        pending = nil
    }

    private func track() -> LayoutMapping.Result {
        generation &+= 1
        let armed = generation, workspace = workspace
        // view-observation-allow: ServiceObservation (p06-scheduler-026) is not on this base and hands its apply no cause; VisibleObservation holds the apply while hidden, and a hidden workspace must still take its handles
        return withObservationTracking {
            LayoutMapping.shared.map(workspace)
        } onChange: { @Sendable [weak self] in
            // main-hop-allow: runs inline in the will-set's turn on main, where the change's cause is current; only an off-main will-set hops, as in VisibleObservation
            MainDelivery().run { [weak self] in self?.willChange(armed) }
        }
    }

    private func willChange(_ armed: UInt64) { // perf-hot: 0.01ms frame-tick (each observed will-set)
        guard !cancelled, armed == generation else { return }
        let cause = work.causes.currentCause
        let previous = pending
        if previous.map({ cause > $0 }) ?? true {
            pending = cause
            if previous.map(Self.flushClass) != Self.flushClass(cause) { post(Self.flushClass(cause)) }
        }
        // Only a higher cause changes the apply now; person is the highest.
        if pending != .person { _ = track() }
    }

    /// The class the apply of `cause` runs in.
    private static func flushClass(_ cause: ObservationCause) -> BudgetedWorkClass {
        cause == .automation ? .automation : .visible
    }

    private func post(_ taskClass: BudgetedWorkClass) {
        // node-free: an off-screen workspace still takes its handles (commands translate through them) and keeps the tree for its show
        work.post(taskClass, owner: owner) { [weak self] in self?.flush(taskClass) }
    }

    /// A posted apply: applies when the pending cause's class is still `taskClass` (a raised
    /// cause has its own task in the higher class).
    private func flush(_ taskClass: BudgetedWorkClass) {
        guard !cancelled, let cause = pending, Self.flushClass(cause) == taskClass else { return }
        pending = nil
        apply(track(), cause)
    }
}
