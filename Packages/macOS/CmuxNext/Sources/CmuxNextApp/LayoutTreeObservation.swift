import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextWakeups
import Observation

/// Follows one workspace's layout mapping for its ``WorkspaceContentController`` and remembers
/// who caused the changes (p06-scheduler-038): the controller applies each new mapping with the
/// highest cause of the changes since its last apply, so the layout can tell an agent's burst of
/// splits from a person's split (``LayoutAutomationBurst``).
///
/// The cause is read at Observation's will-set, in the turn of the change (the daemon store's
/// drain sets it per envelope, an action run per origin). With `raisesCause`, until it is person,
/// the tracking is armed again in that turn, so a later change before the apply can raise it, as
/// ``VisibleObservation`` does. The apply runs one main-actor hop after the first change, behind
/// the job that made it: the changes of one job give one apply.
@MainActor
final class LayoutTreeObservation {
    private let workspace: WorkspaceModel
    private let causes: ObservationCauses
    private let apply: @MainActor (LayoutMapping.Result, ObservationCause) -> Void
    /// Arms the tracking again at a change, so later changes raise the cause (one mapping read per
    /// change until the cause is person). Off, the cause is that of the first change.
    private let raisesCause: Bool
    /// The highest cause of the changes since the last apply; nil while none is pending.
    private var pending: ObservationCause?
    /// The armed tracking's generation; a callback of an older one is stale.
    private var generation: UInt64 = 0
    private var cancelled = false

    /// - Parameters:
    ///   - workspace: The workspace whose mapping it follows.
    ///   - causes: The app's causes (`MainWorkScheduler.causes`).
    ///   - raisesCause: Whether a later change before the apply raises its cause (the layout reads
    ///     the cause only with an automation burst).
    ///   - apply: Applies a new mapping with the cause of its changes.
    init(_ workspace: WorkspaceModel, causes: ObservationCauses, raisesCause: Bool,
         apply: @escaping @MainActor (LayoutMapping.Result, ObservationCause) -> Void) {
        self.workspace = workspace
        self.causes = causes
        self.raisesCause = raisesCause
        self.apply = apply
    }

    /// The mapping now, tracked: the first frame's apply. Later changes go to `apply`.
    func start() -> LayoutMapping.Result {
        track()
    }

    /// No later apply. The armed tracking fires once more at the next change and does nothing.
    func cancel() {
        cancelled = true
        generation &+= 1
        pending = nil
    }

    private func track() -> LayoutMapping.Result {
        generation &+= 1
        let armed = generation, workspace = workspace
        return withObservationTracking {
            LayoutMapping.shared.map(workspace)
        } onChange: { @Sendable [weak self] in
            MainDelivery().run { [weak self] in self?.willChange(armed) }
        }
    }

    private func willChange(_ armed: UInt64) {
        guard !cancelled, armed == generation else { return }
        let cause = causes.currentCause
        let first = pending == nil
        pending = max(pending ?? cause, cause)
        if first { Task { @MainActor [weak self] in self?.flush() } }
        // Only a higher cause changes the apply now; person is the highest.
        if raisesCause, pending != .person { _ = track() }
    }

    private func flush() {
        guard !cancelled, let cause = pending else { return }
        pending = nil
        apply(track(), cause)
    }
}
