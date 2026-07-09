internal import Foundation
public import Observation

/// Owns the lifecycle of restoring keyboard focus after the command palette is
/// dismissed.
///
/// When the palette dismisses with `restoreFocus`, the host hands this
/// controller the focus target it captured at present time. The controller
/// holds that target as the single pending target, drives an immediate restore
/// attempt through its ``CommandPaletteFocusGuard``, and arms a bounded timeout
/// that drops the pending target if focus never lands. Retry triggers
/// (surface-focus / first-responder / window-key notifications) call
/// ``attemptRestoreIfNeeded()`` to retry while the target is still pending.
///
/// ## Why this exists (the banned-primitive replacement)
///
/// The previous inline implementation parked the timeout in a
/// `DispatchWorkItem` scheduled with `DispatchQueue.main.asyncAfter`, which
/// `CONVENTIONS` §5 bans (not cancellable through the lifecycle, not testable).
/// This controller replaces it with a structured `Task` that sleeps on an
/// injected `any Clock<Duration>`. Tests pass a virtual clock to advance the
/// deadline deterministically; production passes a `ContinuousClock`.
///
/// ## Cancellation via guards
///
/// The timeout task carries a monotonic `armedGeneration`. Re-arming bumps the
/// generation and cancels the prior task; clearing bumps it too. After the
/// sleep the task only fires when its captured generation still matches and a
/// pending target still exists, so a stale fire is an idempotent no-op even if
/// the cancel races. This mirrors the legacy `workItem?.cancel()` + reassignment
/// contract exactly: the timeout only nils the pending target it was armed for.
///
/// ## Isolation
///
/// `@MainActor` because every read/write happens on the main actor (the palette
/// flows, the retry-trigger notifications, and the focus guard all run there).
/// The guard is held `weak` because the host owns this controller; the type is
/// parameterized over the host's `Guard` so the guard's `Target` is the host's
/// own focus-target value and no app type crosses the boundary.
@MainActor
@Observable
public final class CommandPaletteFocusRestoreController<Guard: CommandPaletteFocusGuard> {
    /// The target the controller is currently trying to restore focus to, or
    /// `nil` when no restore is in flight. Single writer: this controller.
    public private(set) var pendingTarget: Guard.Target?

    /// How long to keep retrying before dropping the pending target.
    ///
    /// Frozen at the legacy `0.5`-second `asyncAfter` deadline.
    public static var defaultTimeout: Duration { .milliseconds(500) }

    @ObservationIgnored private weak var focusGuard: Guard?
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var armedGeneration: UInt64 = 0

    /// Creates a focus-restore controller.
    ///
    /// - Parameters:
    ///   - focusGuard: The live-responder seam, held weakly (the host owns this
    ///     controller). May be attached later via ``attach(_:)``.
    ///   - clock: The clock the timeout sleeps on. Defaults to
    ///     `ContinuousClock()`; tests inject a virtual clock.
    ///   - timeout: How long the pending target survives without a successful
    ///     restore. Defaults to ``defaultTimeout`` (the legacy 0.5s deadline).
    public init(
        focusGuard: Guard? = nil,
        clock: any Clock<Duration> = ContinuousClock(),
        timeout: Duration = CommandPaletteFocusRestoreController.defaultTimeout
    ) {
        self.focusGuard = focusGuard
        self.clock = clock
        self.timeout = timeout
    }

    /// Attaches (or replaces) the live-responder guard.
    ///
    /// Used when the host constructs the controller before its adapter exists.
    public func attach(_ focusGuard: Guard) {
        self.focusGuard = focusGuard
    }

    /// Begins restoring focus to `target`.
    ///
    /// Sets `target` as the single pending target, arms the bounded timeout, and
    /// drives one immediate restore attempt. Re-requesting cancels the prior
    /// timeout and arms a fresh one, matching the legacy
    /// `requestCommandPaletteFocusRestore` reassignment.
    public func request(target: Guard.Target) {
        pendingTarget = target
        armTimeout()
        attemptRestoreIfNeeded()
    }

    /// Retries the restore while a target is still pending.
    ///
    /// No-op when nothing is pending. Otherwise consults the guard:
    /// `paletteStillPresented` keeps waiting; `targetUnavailable` and `restored`
    /// clear the pending target and cancel the timeout; `retryLater` keeps the
    /// pending target so a later trigger (or the timeout) can resolve it.
    public func attemptRestoreIfNeeded() {
        guard let target = pendingTarget, let focusGuard else { return }
        guard !focusGuard.isPaletteStillPresented else { return }

        switch focusGuard.attemptRestore(to: target) {
        case .paletteStillPresented, .retryLater:
            return
        case .targetUnavailable, .restored:
            clear()
        }
    }

    /// Drops any pending target and cancels the timeout without restoring.
    public func clear() {
        pendingTarget = nil
        armedGeneration &+= 1
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func armTimeout() {
        armedGeneration &+= 1
        let generation = armedGeneration
        timeoutTask?.cancel()
        let clock = clock
        let timeout = timeout
        timeoutTask = Task { @MainActor [weak self] in
            try? await clock.sleep(for: timeout, tolerance: nil)
            guard let self else { return }
            // Cancellation via guards: only the still-armed generation fires.
            guard generation == self.armedGeneration else { return }
            guard self.pendingTarget != nil else { return }
            self.pendingTarget = nil
            self.timeoutTask = nil
        }
    }
}
