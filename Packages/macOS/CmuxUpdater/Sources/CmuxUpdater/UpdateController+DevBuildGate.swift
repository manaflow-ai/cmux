public import Foundation

/// DEV/staging release-train gating policy for the updater.
///
/// Pure, `nonisolated` predicates that decide whether the running build is excluded from the
/// public Sparkle release train. Tagged DEV builds (`com.cmuxterm.app.debug[.<tag>]`) and staging
/// builds (`com.cmuxterm.app.staging[.<tag>]`) are produced from local source and must never query
/// the public appcast or surface/install the public release — see
/// https://github.com/manaflow-ai/cmux/issues/6292.
extension UpdateController {
    /// Whether the running bundle is a DEV or staging build that should be excluded from the
    /// public Sparkle release train.
    ///
    /// Mirrors `CmuxSocketControl.SocketControlSettings.isDebugLikeBundleIdentifier` /
    /// `isStagingBundleIdentifier` locally so the updater module does not take a package
    /// dependency on `CmuxSocketControl`. Covers the untagged base ids and every tagged variant
    /// produced by `reload.sh --tag` (`com.cmuxterm.app.debug.<tag>` /
    /// `com.cmuxterm.app.staging.<tag>`).
    public nonisolated static func isDevLikeBundleIdentifier(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier == "com.cmuxterm.app.debug"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.debug.")
            || bundleIdentifier == "com.cmuxterm.app.staging"
            || bundleIdentifier.hasPrefix("com.cmuxterm.app.staging.")
    }

    /// Whether this build should be fully excluded from the public Sparkle release train.
    ///
    /// True for DEV/staging bundle ids, EXCEPT under the UI-test / XCTest harness — those runs
    /// deliberately exercise the update UI on a debug bundle via `CMUX_UI_TEST_*` injection, so
    /// suppressing the updater there would break `UpdatePillUITests` and friends.
    public nonisolated static func shouldSuppressPublicUpdates(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard isDevLikeBundleIdentifier(bundleIdentifier) else { return false }
        return !isUpdateTestHarnessActive(environment: environment)
    }

    /// Whether a UI-test / XCTest harness is driving this process. Mirrors the harness detection
    /// used elsewhere (`CMUX_UI_TEST_*` env injected by XCUITest launches, plus in-process XCTest
    /// indicators).
    public nonisolated static func isUpdateTestHarnessActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment.keys.contains(where: { $0.hasPrefix("CMUX_UI_TEST_") }) {
            return true
        }
        let xctestIndicators = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
        ]
        return xctestIndicators.contains { key in
            guard let value = environment[key] else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
