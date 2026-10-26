@testable import CmuxNextApp
import Testing

/// A bench build (`reload.sh --config bench`: no DEBUG, no dev tools) loads the tunable store only
/// for a development bundle whose bench script names the override file, so a bench run's tunables
/// (chromium-host-bench.py's `browserHost.helper`) apply and a shipped bundle never reads one.
struct DebugSettingsBenchActivationTests {
    private let file = [DebugSettingsService.fileOverrideKey: "/tmp/bench/debug-tunables.json"]

    @Test func devToolsAlwaysLoad() {
        #expect(DebugSettingsService.loadsTunables(devTools: true, benchBuild: false, bundleID: "com.cmuxterm.app.nightly", environment: [:]))
    }

    @Test func aBenchBuildOfADevelopmentBundleLoadsTheBenchFile() {
        #expect(DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: "com.cmuxterm.app.debug.bench-a", environment: file))
        #expect(DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: "com.cmuxterm.app.dev", environment: file))
    }

    @Test func aBenchBuildWithoutTheFileStaysInert() {
        #expect(!DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: "com.cmuxterm.app.debug.bench-a", environment: [:]))
        #expect(!DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: "com.cmuxterm.app.debug.bench-a",
                                                    environment: [DebugSettingsService.fileOverrideKey: "  "]))
    }

    @Test func shippedBundlesAndReleaseCompilesIgnoreTheFile() {
        #expect(!DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: "com.cmuxterm.app", environment: file))
        #expect(!DebugSettingsService.loadsTunables(devTools: false, benchBuild: true, bundleID: nil, environment: file))
        #expect(!DebugSettingsService.loadsTunables(devTools: false, benchBuild: false, bundleID: "com.cmuxterm.app.debug.bench-a", environment: file))
    }
}
