extension UpdateController {
    /// Whether the bounded readiness wait should keep polling for `canCheckForUpdates`, decided from
    /// the model state observed at the top of each poll iteration.
    ///
    /// Kept as a pure value + decision — separate from the controller's effectful readiness wait — so
    /// it is unit-testable without the live `SPUUpdater` the controller owns, mirroring
    /// ``TransientRetryPlan``.
    ///
    /// The wait is entered on behalf of a pending check and must keep polling for readiness for any
    /// pending state — a `.checking` placeholder (a plain manual check or a transient-retry pill) or
    /// the `.updateAvailable` prompt that `attemptUpdate()` re-resolves to the latest version
    /// (issue #6366). It stops only when the model has returned to `.idle`, the signal that the user
    /// cancelled the pending check, so readiness arriving later cannot resurrect a dismissed check.
    /// Stopping on every non-`.checking` state instead stranded `attemptUpdate()`'s install whenever
    /// Sparkle was briefly not ready, leaving the model `.updateAvailable` so no fresh check ran
    /// (autoreview follow-up to issue #5632).
    enum ReadinessWaitDecision: Equatable {
        /// A pending check still awaits readiness; keep polling `canCheckForUpdates`.
        case keepPolling
        /// The pending check was cancelled back to `.idle`; stop the wait.
        case stop

        nonisolated init(modelState state: UpdateState) {
            self = state.isIdle ? .stop : .keepPolling
        }
    }
}
