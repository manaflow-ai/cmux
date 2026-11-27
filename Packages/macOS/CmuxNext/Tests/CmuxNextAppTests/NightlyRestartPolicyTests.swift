@testable import CmuxNextUpdater
import Testing

/// The nightly restart policy (Lawrence 2026-10-27): updates check and download by themselves,
/// but the app never restarts by itself. The restart happens only when the person clicks
/// Restart to Update. So a quit never installs a staged update unless the person asked for it.
@MainActor @Suite struct NightlyRestartPolicyTests {
    /// The shipped default: a quit leaves the staged update for the next click, it does not
    /// install and relaunch.
    @Test func installOnQuitIsOffByDefault() {
        #expect(UpdatePreferences.defaults.installOnQuit == false)
        #expect(UpdatePreferences().installOnQuit == false)
    }

    /// With the default preferences, quitting a staged update cancels Sparkle's pending installer:
    /// nothing installs or relaunches behind the person's back.
    @Test func quittingWithAStagedUpdateCancelsTheInstallByDefault() {
        var flow = UpdateFlow()
        _ = flow.handle(.sparkle(.ready(version: "1.0.1")), preferences: .defaults)
        #expect(flow.handle(.quitRequested, preferences: .defaults) == [.quit(.cancelPendingInstall)])
    }
}
