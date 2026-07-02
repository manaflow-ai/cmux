import Foundation

extension UpdateController {
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
