import Testing
@testable import CmuxNextActions

/// Debug Settings and other developer tools exist in DEV and NIGHTLY builds
/// only; Release and RC never list them.
@Suite struct DevToolsGateTests {
    @Test func debugCompilesAlwaysHaveDevTools() {
        for bundle in [nil, "com.cmuxterm.app", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.nxtun"] {
            #expect(DevTools.isAvailable(bundleID: bundle, isDebugBuild: true))
        }
    }

    @Test func releaseCompilesHaveThemOnlyAsNightly() {
        #expect(DevTools.isAvailable(bundleID: "com.cmuxterm.app.nightly", isDebugBuild: false))
        #expect(DevTools.isAvailable(bundleID: "com.cmuxterm.app.nightly.tag", isDebugBuild: false))
        for bundle in [nil, "", "com.cmuxterm.app", "com.cmuxterm.app.rc", "com.cmuxterm.app.rc.tag", "com.cmuxterm.app.staging",
                       "com.cmuxterm.app.nightlyx", "com.cmuxterm.app.debug"] {
            #expect(!DevTools.isAvailable(bundleID: bundle, isDebugBuild: false), "\(bundle ?? "nil") must not offer dev tools")
        }
    }

    @Test func openDebugSettingsIsADevToolWithACLIVerb() throws {
        let descriptor = try #require(ActionCatalog.all.first { $0.id == "openDebugSettings" })
        #expect(descriptor.isDebugOnly)
        #expect(descriptor.cliName == "debug open-settings")
        #expect(descriptor.isPaletteVisible)
        // Availability follows the gate (this test process is a Debug compile).
        #expect(ActionRegistry.isAvailable(descriptor, in: []) == DevTools.isEnabled)
    }
}
