import Foundation

/// Sequences the "re-resolve to the latest, then install" flow so the update that actually gets
/// installed is the newest one currently published — not the version that was captured when the
/// update prompt was first surfaced.
///
/// Background (issue #6366): Sparkle resolves an appcast item when a check finds an update and
/// hands it to the UI. If the user installs from that prompt later, replying `.install` installs
/// *that captured item*, even if a newer release shipped in the meantime. The user then relaunches
/// straight into another "update available" prompt. The fix is to always run a fresh check at
/// install time and install whatever that fresh check resolves.
///
/// The coordinator is intentionally pure — it has no Sparkle dependency and performs no work
/// itself. ``UpdateController`` feeds it the user's request plus each subsequent ``UpdateState``
/// change and performs the returned ``Action``. Keeping the policy here (rather than inline in the
/// controller, which owns a live `SPUUpdater`) makes the install-resolution behavior deterministic
/// and unit-testable without a live updater.
@MainActor
struct AttemptUpdateCoordinator {
    /// What the controller should do in response to a request or a state change.
    enum Action: Equatable {
        /// Do nothing; keep waiting for the next state change.
        case none
        /// Start a fresh Sparkle check so the feed is re-resolved to the latest available version.
        case startFreshCheck
        /// Install the update the model is currently carrying (now known to be the freshly
        /// resolved latest version).
        case confirmInstall
    }

    private enum Phase: Equatable {
        /// Not coordinating an install.
        case inactive
        /// A fresh check was requested. The prompt that was on screen when the user asked may be
        /// stale, so ignore any lingering `.updateAvailable` until the check actually restarts.
        case awaitingCheckRestart
        /// The stale prompt has been dismissed, but Sparkle has not yet surfaced the fresh
        /// `.checking` state. Duplicate idle notifications in this window are still part of the
        /// restart path, not a user cancellation.
        case awaitingCheckStart
        /// The check has restarted; install the next update it resolves.
        case awaitingResult
    }

    private var phase: Phase = .inactive

    /// Whether the coordinator is mid-flow and should be fed state changes.
    var isMonitoring: Bool { phase != .inactive }

    /// The user asked to install the available update. Always re-resolve via a fresh check rather
    /// than installing whatever was captured when the prompt was surfaced (issue #6366), unless an
    /// install is already in progress (in which case there is nothing newer to resolve and
    /// restarting would interrupt it).
    ///
    /// - Parameter currentState: The phase showing when the user requested the install. Its
    ///   captured update is deliberately *not* installed; it only gates the mid-install no-op.
    mutating func requestInstallLatest(currentState: UpdateState) -> Action {
        switch currentState {
        case .downloading, .extracting, .installing:
            // An install is already underway; don't interrupt it to re-resolve.
            return .none
        case .idle, .permissionRequest, .checking, .updateAvailable, .notFound, .error:
            // Ignore any update captured in `currentState`; re-resolve the feed to the latest.
            phase = .awaitingCheckRestart
            return .startFreshCheck
        }
    }

    /// Arm the coordinator to auto-confirm the update a freshly *restarted* retry check resolves,
    /// entering ``Phase/awaitingResult`` directly rather than ``Phase/awaitingCheckRestart``.
    ///
    /// Used by the download-phase transient-retry re-arm (issue #5632). Unlike
    /// ``requestInstallLatest(currentState:)`` — invoked while a stale pre-request `.updateAvailable`
    /// prompt may still be on screen, which `awaitingCheckRestart` exists to ignore until a real
    /// check restarts — this arm happens while the model is the retry's own `.checking` pill, so
    /// there is no stale prompt to gate against. Entering `awaitingResult` directly means that if the
    /// user cancels the retry before the check restarts (idling the model, e.g. during the
    /// controller's readiness wait), the coordinator disarms via the `awaitingResult` idle → inactive
    /// path instead of misreading the idle as check-restart progress — which would otherwise strand
    /// it armed to silently auto-confirm a later, unrelated update.
    mutating func armForConfirmedRetryCheck() {
        phase = .awaitingResult
    }

    /// Feed each ``UpdateState`` change observed after a request. Returns the action the controller
    /// should perform.
    mutating func handleStateChange(_ state: UpdateState) -> Action {
        switch phase {
        case .inactive:
            return .none

        case .awaitingCheckRestart:
            switch state {
            case .updateAvailable:
                // Still the pre-request prompt (or a coalesced repeat of it); keep waiting for the
                // fresh check to actually start before trusting an `.updateAvailable`.
                return .none
            case .idle:
                // The stale prompt was cleared. Sparkle can emit another idle notification before
                // the fresh check starts (#7235), so do not treat idle as cancellation yet.
                phase = .awaitingCheckStart
                return .none
            case .checking, .downloading, .extracting, .installing, .permissionRequest:
                // The check has restarted. Confirm whatever it resolves next.
                phase = .awaitingResult
                return .none
            case .notFound, .error:
                // The fresh check ended without an update; stop coordinating.
                phase = .inactive
                return .none
            }

        case .awaitingCheckStart:
            switch state {
            case .idle, .updateAvailable:
                // Duplicate idle/stale-available emissions can arrive while Sparkle is tearing
                // down the dismissed prompt. Keep waiting for the fresh check to begin.
                return .none
            case .checking, .downloading, .extracting, .installing, .permissionRequest:
                phase = .awaitingResult
                return .none
            case .notFound, .error:
                phase = .inactive
                return .none
            }

        case .awaitingResult:
            switch state {
            case .updateAvailable:
                phase = .inactive
                return .confirmInstall
            case .idle, .notFound, .error:
                // The fresh check ended without resolving an update: it was cancelled (the user hit
                // Cancel in the checking popover, which returns the model to idle), found nothing,
                // or errored. Stop coordinating so a later unrelated check is not auto-confirmed
                // without the user asking to install.
                phase = .inactive
                return .none
            case .checking, .downloading, .extracting, .installing, .permissionRequest:
                return .none
            }
        }
    }

    /// Abandon any in-flight coordination (e.g. when a different flow takes over).
    mutating func cancel() {
        phase = .inactive
    }
}
