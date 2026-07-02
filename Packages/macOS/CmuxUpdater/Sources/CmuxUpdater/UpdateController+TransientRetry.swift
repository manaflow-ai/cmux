extension UpdateController {
    /// How ``retryAfterTransientFailure(preservingInstallIntent:)`` should react to a transient
    /// Sparkle download failure.
    ///
    /// Kept as a pure value + decision — separate from the controller's effectful retry method — so
    /// it is unit-testable without the live `SPUUpdater` the controller owns, mirroring how
    /// ``AttemptUpdateCoordinator`` isolates the install re-resolution policy.
    enum TransientRetryPlan: Equatable {
        /// The attempt coordinator is already sequencing an install; restart its check while
        /// preserving the in-flight install intent so it still auto-confirms.
        case restartMonitoredCheck
        /// The failure landed in a Sparkle download/extract/install phase, but the coordinator was
        /// not yet monitoring (the interrupted session was Sparkle's own, not a coordinator
        /// re-resolve). Re-arm the coordinator so the retried check auto-confirms the update it
        /// finds; otherwise the retry surfaces a fresh prompt and the interrupted install is
        /// silently stranded.
        case rearmConfirmedInstall
        /// A plain transient retry with no install intent to preserve; run an ordinary fresh check.
        case plainCheck
    }

    /// Pure decision for ``retryAfterTransientFailure(preservingInstallIntent:)``; see
    /// ``TransientRetryPlan`` for what each case means.
    nonisolated static func transientRetryPlan(
        preservingInstallIntent: Bool,
        coordinatorIsMonitoring: Bool
    ) -> TransientRetryPlan {
        // BUG (issue #5632 follow-up): a preserved-intent retry that is not already being monitored
        // is collapsed into the monitored-restart path, so the coordinator is never armed and the
        // retried check surfaces a prompt instead of auto-confirming the update it finds.
        if preservingInstallIntent || coordinatorIsMonitoring { return .restartMonitoredCheck }
        return .plainCheck
    }
}
