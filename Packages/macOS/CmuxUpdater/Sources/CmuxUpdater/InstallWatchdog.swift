import Foundation

/// Guards against the update flow silently stalling after the user asks to install.
///
/// When the user clicks Install, ``UpdateController`` arms this watchdog with a bounded,
/// cancellable deadline (``installWatchdogTimeout``). If the flow reaches a state
/// that either progresses the install or communicates a clear outcome, the controller disarms it.
/// If the deadline elapses while the flow is still merely checking or showing "Update Available"
/// with nothing downloading, the controller surfaces a visible "Update Didn't Start" error rather
/// than leaving the user staring at a pill that never advances.
///
/// The watchdog owns only its timer; the *decision* of what counts as stalled vs. resolved lives
/// in the two pure, exhaustively-tested static predicates below, and the error-surfacing side
/// effect stays in the controller (which owns the model). This mirrors ``AttemptUpdateCoordinator``:
/// a small, single-purpose collaborator kept out of the controller so its policy is testable in
/// isolation and the controller file stays focused.
@MainActor
final class InstallWatchdog {
    private let clock: any UpdateClock
    private let timeout: TimeInterval
    private var task: Task<Void, Never>?

    /// The configured deadline, exposed for diagnostics/logging.
    var timeoutSeconds: TimeInterval { timeout }

    init(clock: any UpdateClock, timeout: TimeInterval) {
        self.clock = clock
        self.timeout = timeout
    }

    deinit {
        task?.cancel()
    }

    /// Whether a deadline is currently pending.
    var isArmed: Bool { task != nil }

    /// (Re)arms the deadline. Cancels any prior timer so repeated Install clicks reset the
    /// countdown rather than stacking. `onTimeout` runs on the main actor if the deadline elapses
    /// before ``disarm()`` is called.
    func arm(onTimeout: @escaping @MainActor () -> Void) {
        task?.cancel()
        let timeout = self.timeout
        task = Task { @MainActor [weak self] in
            // Bounded, cancellable deadline via the injected clock.
            try? await self?.clock.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, self != nil else { return }
            onTimeout()
        }
    }

    /// Cancels any pending deadline.
    func disarm() {
        task?.cancel()
        task = nil
    }

    /// Whether `state`, observed when the watchdog fires, means the install never got going: the
    /// user asked to install but the flow is still merely checking, showing "Update Available",
    /// or sitting at `.idle` with no download underway. `.idle` counts as stalled because every
    /// legitimate way to be idle at the deadline disarms first (a user-cancelled fresh check ends
    /// the attempt via ``attemptEndedWithoutInstall(action:isCoordinatorMonitoring:)``; terminal
    /// outcomes disarm via ``installAttemptResolved(_:)``) — so an armed deadline firing at idle
    /// is the pre-check stall where the delayed re-check was dropped and `.checking` never came.
    /// `.permissionRequest` stays not-stalled (a state cmux never surfaces; erroring over it
    /// would be wrong if Sparkle ever did).
    func installAttemptStalled(_ state: UpdateState) -> Bool {
        switch state {
        case .checking, .updateAvailable, .idle:
            return true
        case .permissionRequest, .downloading, .extracting, .installing, .notFound, .error:
            return false
        }
    }

    /// Whether `state` resolves the attempt — either it is actively progressing the install or it
    /// is a clearly-communicated terminal outcome — so the watchdog can be disarmed.
    func installAttemptResolved(_ state: UpdateState) -> Bool {
        switch state {
        case .downloading, .extracting, .installing, .notFound, .error:
            return true
        case .idle, .permissionRequest, .checking, .updateAvailable:
            return false
        }
    }

    /// Whether feeding a state change to ``AttemptUpdateCoordinator`` just ended the install
    /// attempt without handing an install to Sparkle: the coordinator stopped monitoring for any
    /// reason other than `.confirmInstall` (the user cancelled the fresh check back to idle, or
    /// it terminated in notFound/error). The watchdog is bound to the attempt that armed it, so
    /// the controller disarms on this — a deadline that outlives its attempt would otherwise fire
    /// a spurious "Update Didn't Start" over a later, unrelated check that happens to be sitting
    /// in `.checking`/`.updateAvailable`.
    func attemptEndedWithoutInstall(action: AttemptUpdateCoordinator.Action,
                                    isCoordinatorMonitoring: Bool) -> Bool {
        !isCoordinatorMonitoring && action != .confirmInstall
    }
}
