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

        /// Pure decision for ``UpdateController/retryAfterTransientFailure(preservingInstallIntent:)``,
        /// derived from the retry context alone so it stays unit-testable without the live
        /// `SPUUpdater` the controller owns.
        ///
        /// A retry while the attempt coordinator is already monitoring just restarts its in-flight
        /// check (intent preserved by the coordinator itself). A preserved-intent retry that arrives
        /// *before* the coordinator is monitoring must re-arm it so the retried check auto-confirms
        /// the update it resolves — the case that previously stranded the interrupted install by
        /// falling through to a bare check that only surfaced a prompt (issue #5632).
        nonisolated init(preservingInstallIntent: Bool, coordinatorIsMonitoring: Bool) {
            if coordinatorIsMonitoring {
                self = .restartMonitoredCheck
            } else if preservingInstallIntent {
                self = .rearmConfirmedInstall
            } else {
                self = .plainCheck
            }
        }
    }
}
