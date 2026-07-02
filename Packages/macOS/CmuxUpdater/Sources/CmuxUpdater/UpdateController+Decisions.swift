import Foundation

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

    /// Which release channel a bundle identifier belongs to, decided from the identifier alone so it
    /// stays unit-testable, mirroring ``TransientRetryPlan``.
    ///
    /// cmux DEV (`com.cmuxterm.app.debug[.<tag>]`) and staging (`com.cmuxterm.app.staging[.<tag>]`)
    /// builds are produced from local source and are not on the public release train, so they must
    /// never be compared against the public Sparkle appcast (#6292).
    ///
    /// Mirrors `SocketControlSettings.isDebugLikeBundleIdentifier` + `isStagingBundleIdentifier` (in
    /// the CmuxSettings package). The classification is duplicated here deliberately to avoid
    /// introducing a `CmuxUpdater → CmuxSettings` package dependency edge for a small string check.
    enum BundleReleaseChannel: Equatable {
        /// A DEV or staging build produced from local source; never query the public appcast.
        case devLike
        /// A public release-train build; the appcast applies.
        case release

        nonisolated init(bundleIdentifier: String?) {
            guard let bundleIdentifier else { self = .release; return }
            let isDevLike = bundleIdentifier == "com.cmuxterm.app.debug"
                || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
                || bundleIdentifier == "com.cmuxterm.app.staging"
                || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
            self = isDevLike ? .devLike : .release
        }
    }
}
