import Foundation
import CmuxNextCloud
import CmuxNextCompat
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
    @Test func signedDEVOnTheNightlyAccountUsesProductionAndNightlysSession() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:],
                                                isDebugBuild: false, devAccount: .nightly)
        #expect(config.isProductionAuth)
        #expect(config.backend == .production)
        #expect(config.apiBaseURL.absoluteString == "https://cmux.com")
        #expect(config.stackProjectID == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(config.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cloud-api.cmux.dev")
        #expect(config.callbackURL.absoluteString == "cmux-next-dev://auth-callback")
        #expect(config.linkSource == .appServer)
        // Its own production namespace: neither the staging session nor the old unscoped one.
        #expect(config.keychainService == "com.cmuxterm.app.debug.next.auth.9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(config.nightlySession?.keychainService == "com.cmuxterm.app.nightly.auth")
        #expect(config.nightlySession?.accessGroup == "7WLXT3NR37.com.cmuxterm.app.nightly")
        #expect(config.nightlySession?.credentialsDirectory.path.hasSuffix("Library/Application Support/cmux/com.cmuxterm.app.nightly") == true)
        // The root comes from the resolver keyed on NIGHTLY's identity, never a
        // literal one, so it follows BuildIdentity's rules (per-build isolation
        // S7, cx-is1kf.8; scripts/cmux-next/check-state-roots.sh).
        let nightly = BuildIdentity.nightlyBundleID
        let resolved = BuildIdentity(bundleID: nightly, bundledTag: nil)
            .appSupport(FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true))
            .appendingPathComponent(nightly, isDirectory: true)
        #expect(config.nightlySession?.credentialsDirectory == resolved)
    }

    @Test func onlySignedDEVOnTheNightlyAccountAdoptsNightlysSession() {
        let staging = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(staging.nightlySession == nil)
        for (bundleID, debug) in [("com.cmuxterm.app.nightly", false), ("com.cmuxterm.app.debug.next", true), ("com.cmuxterm.app", false)] {
            let config = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: debug, devAccount: .nightly)
            #expect(config.nightlySession == nil, "\(bundleID) debug=\(debug)")
            #expect(config == CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: debug))
        }
    }

    @Test func theLaunchsDevAccountIsKeptForTheNextLaunch() throws {
        let suite = "cmux-dev-account-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(CloudConfiguration.devAccount(environment: [:], defaults: defaults) == .staging)
        #expect(CloudConfiguration.devAccount(environment: ["CMUX_NEXT_DEV_ACCOUNT": " Nightly "], defaults: defaults) == .nightly)
        // An update's relaunch carries no launch environment.
        #expect(CloudConfiguration.devAccount(environment: [:], defaults: defaults) == .nightly)
        #expect(CloudConfiguration.devAccount(environment: ["CMUX_NEXT_DEV_ACCOUNT": "bogus"], defaults: defaults) == .nightly)
        #expect(CloudConfiguration.devAccount(environment: ["CMUX_NEXT_DEV_ACCOUNT": "staging"], defaults: defaults) == .staging)
        #expect(CloudConfiguration.devAccount(environment: [:], defaults: defaults) == .staging)
    }
}
