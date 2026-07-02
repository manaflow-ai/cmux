import Foundation

extension UpdateController {
    /// Whether the bounded readiness wait should keep polling for `canCheckForUpdates`, given the
    /// model state observed at the top of each poll iteration.
    ///
    /// The wait is entered on behalf of a pending check and must keep polling for readiness for any
    /// pending state — a `.checking` placeholder (a plain manual check or a transient-retry pill) or
    /// the `.updateAvailable` prompt that `attemptUpdate()` re-resolves to the latest version
    /// (issue #6366). It stops only when the model has returned to `.idle`, the signal that the user
    /// cancelled the pending check (e.g. Cancel on the retry/checking pill idles the model), so
    /// readiness arriving later does not resurrect a dismissed check. Aborting on every non-`.checking`
    /// state instead stranded `attemptUpdate()`'s install whenever Sparkle was briefly not ready,
    /// leaving the model `.updateAvailable` — not `.checking` — so no fresh check ran (autoreview
    /// follow-up to issue #5632).
    static func readinessWaitShouldContinue(whileModelState state: UpdateState) -> Bool {
        if case .idle = state { return false }
        return true
    }

    /// Whether `bundleIdentifier` is a cmux DEV (`com.cmuxterm.app.debug[.<tag>]`) or staging
    /// (`com.cmuxterm.app.staging[.<tag>]`) build.
    ///
    /// Such builds are produced from local source and are not on the public release train, so
    /// they must never be compared against the public Sparkle appcast (#6292).
    ///
    /// Mirrors `SocketControlSettings.isDebugLikeBundleIdentifier` +
    /// `isStagingBundleIdentifier` (in the CmuxSettings package). The classification is
    /// duplicated here deliberately to avoid introducing a `CmuxUpdater → CmuxSettings` package
    /// dependency edge for a small string check.
    static func isDevLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
            || bundleIdentifier == "com.cmuxterm.app.staging"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
    }
}
