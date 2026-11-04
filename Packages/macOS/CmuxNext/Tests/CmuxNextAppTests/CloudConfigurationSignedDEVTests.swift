import CmuxNextCloud
import Testing

struct CloudConfigurationSignedDEVTests {
    @Test func runtimeSelectionUsesTheBackendValuesWithoutBuildPins() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(config.linkSource == .appServer)
        #expect(config.ownerAPIBaseURL(environment: [:]) == config.runtimeSelection?.apiOrigin)
        #expect(config.apiBaseURL == config.runtimeSelection?.apiOrigin)
        #expect(config.authWebOrigin == config.runtimeSelection?.authWebOrigin)
        #expect(config.stackProjectID == config.runtimeSelection?.stackProjectId)
        #expect(!config.isProductionAuth)
        #expect(!config.isDebugBuild)
        #expect(config.callbackURL.absoluteString.hasSuffix("://auth-callback"))
        #expect(config.keychainService.hasPrefix("com.cmuxterm.app.debug.next.auth."))
        #expect(config.backend == .development(config.apiBaseURL))
    }

    @Test func selectedOriginIsNotReplacedByProcessOverrides() {
        let origin = "https://selected.fixture.invalid"
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next",
            bundled: ["CMUX_VM_API_BASE_URL": origin], process: ["CMUX_VM_API_BASE_URL": "https://wrong.fixture.invalid"], isDebugBuild: false)
        #expect(config.ownerAPIBaseURL() == URL(string: origin))
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                      "com.cmuxterm.app.rc", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next.other", "com.cmuxterm.app.debug.nextx"])
    func otherReleaseChannelsKeepProduction(bundleID: String) {
        let config = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: false)
        // Production auth uses NEXT Cloud through the production owner API (cmux-api, which forwards
        // Cloud to cmux-platform-production), the same app-server link signed DEV builds use.
        #expect(config.linkSource == .appServer)
        #expect(config.isProductionAuth)
        #expect(config.apiBaseURL == config.runtimeSelection?.apiOrigin)
        #expect(config.ownerAPIBaseURL() == config.apiBaseURL)
    }

    @Test func onlyABenchCaptureBuildIsConfiguredAsDebug() {
        #expect(CloudConfiguration.isCaptureBuild(bundleID: "com.cmuxterm.app.debug.cap0123456789", benchHooks: true))
        #expect(CloudConfiguration.isCaptureBuild(bundleID: "com.cmuxterm.app.debug.capabcdef0123", benchHooks: true))
        // Without the bench hooks (every shipped and plain Release build), never.
        #expect(!CloudConfiguration.isCaptureBuild(bundleID: "com.cmuxterm.app.debug.cap0123456789", benchHooks: false))
        for bundleID in [nil, "com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.rc", "com.cmuxterm.app.debug.next",
                         "com.cmuxterm.app.debug.chrome.parity.x", "com.cmuxterm.app.debug.cap012345678",
                         "com.cmuxterm.app.debug.cap0123456789a", "com.cmuxterm.app.debug.capABCDEF0123",
                         "com.cmuxterm.app.debug.cap0123456789.x", "com.cmuxterm.app.nightly.cap0123456789"] {
            #expect(!CloudConfiguration.isCaptureBuild(bundleID: bundleID, benchHooks: true), "\(bundleID ?? "nil")")
        }
        // A capture helper may still use a runtime fixture, but it has no baked host.
        let capture = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.cap0123456789", bundled: [:], process: [:], isDebugBuild: true)
        #expect(!capture.isProductionAuth)
        #expect(capture.ownerAPIBaseURL() == capture.runtimeSelection?.apiOrigin)
    }

    @Test func debugBuildUsesItsSelectedRuntimeOrigin() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: ["CMUX_VM_API_BASE_URL": "https://debug.fixture.invalid"], process: [:], isDebugBuild: true)
        #expect(config.linkSource == .appServer)
        #expect(config.ownerAPIBaseURL() == URL(string: "https://debug.fixture.invalid"))
    }
}
