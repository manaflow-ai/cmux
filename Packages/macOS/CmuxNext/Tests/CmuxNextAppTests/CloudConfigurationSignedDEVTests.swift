import Foundation
import CmuxNextCloud
import Testing

struct CloudConfigurationSignedDEVTests {
    @Test func signedDEVUsesTheDevelopmentCloudWithoutLaunchOverrides() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(config.linkSource == .appServer)
        #expect(config.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cmux-api-development.debussy.workers.dev")
        #expect(config.apiBaseURL.absoluteString == "https://cmux-staging.vercel.app")
        #expect(config.authWebOrigin.absoluteString == "https://cmux-staging.vercel.app")
        #expect(config.stackProjectID == "454ecd03-1db2-4050-845e-4ce5b0cd9895")
        #expect(!config.isProductionAuth)
        #expect(!config.isDebugBuild)
        #expect(config.callbackURL.absoluteString == "cmux-next-dev://auth-callback")
        #expect(config.keychainService == "com.cmuxterm.app.debug.next.auth.454ecd03-1db2-4050-845e-4ce5b0cd9895")
        #expect(config.backend == .development(config.apiBaseURL))
    }

    @Test func signedDEVDoesNotAcceptEndpointOrAuthOverrides() {
        let overrides = ["CMUX_AUTH_ENVIRONMENT": "production", "CMUX_STACK_BASE_URL": "https://override.invalid",
                         "CMUX_STACK_PROJECT_ID": "other-project", "CMUX_API_BASE_URL": "https://override.invalid",
                         "CMUX_AUTH_WWW_ORIGIN": "https://override.invalid", "CMUX_NEXT_FEED_API_URL": "https://override.invalid",
                         "CMUX_AUTH_CALLBACK_SCHEME": "other-app", "CMUX_NEXT_CLOUD_LINK": "legacy"]
        let baseline = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: overrides, process: overrides, isDebugBuild: false)
        #expect(config == baseline)
        #expect(config.ownerAPIBaseURL(environment: overrides) == baseline.ownerAPIBaseURL(environment: [:]))
    }

    @Test(arguments: ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.nightly.cmux-next",
                      "com.cmuxterm.app.rc", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next.other", "com.cmuxterm.app.debug.nextx"])
    func otherReleaseChannelsKeepProduction(bundleID: String) {
        let config = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: false)
        // Production auth uses NEXT Cloud through the production owner API (cmux-api, which forwards
        // Cloud to cmux-platform-production), the same app-server link signed DEV builds use.
        #expect(config.linkSource == .appServer)
        #expect(config.isProductionAuth)
        #expect(config.apiBaseURL.absoluteString == "https://cmux.com")
        #expect(config.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cloud-api.cmux.dev")
    }

    @Test(arguments: [["CMUX_NEXT_CLOUD_LINK": "legacy"], ["CMUX_CLOUD_LINK": "LEGACY"]])
    func productionKeepsTheLegacyEscapeHatch(bundled: [String: String]) {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.nightly.cmux-next", bundled: bundled, process: [:], isDebugBuild: false)
        #expect(config.linkSource == .legacy)
        #expect(config.isProductionAuth)
        let launched = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.nightly.cmux-next", bundled: [:],
                                                  process: ["CMUX_NEXT_CLOUD_LINK": "legacy"], isDebugBuild: false)
        #expect(launched.linkSource == .legacy)
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
        // Configured as Debug, a capture build is on the development backend and Worker, not production.
        let capture = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.cap0123456789", bundled: [:], process: [:], isDebugBuild: true)
        #expect(!capture.isProductionAuth)
        #expect(capture.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cmux-api-development.debussy.workers.dev")
    }

    @Test func debugBuildKeepsItsExplicitLinkAndWorkerOverrides() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: ["CMUX_CLOUD_LINK": "app"], process: [:], isDebugBuild: true)
        #expect(config.linkSource == .appServer)
        #expect(config.ownerAPIBaseURL(environment: ["CMUX_NEXT_FEED_API_URL": "https://override.invalid"]).absoluteString == "https://override.invalid")
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
        #expect(config.adoptsNightlySession)
    }

    @Test func onlySignedDEVOnTheNightlyAccountAdoptsNightlysSession() {
        let staging = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        #expect(!staging.adoptsNightlySession)
        for (bundleID, debug) in [("com.cmuxterm.app.nightly", false), ("com.cmuxterm.app.debug.next", true), ("com.cmuxterm.app", false)] {
            let config = CloudConfiguration.resolve(bundleID: bundleID, bundled: [:], process: [:], isDebugBuild: debug, devAccount: .nightly)
            #expect(!config.adoptsNightlySession, "\(bundleID) debug=\(debug)")
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

    @Test func withoutARunningNightlyTheNightlyAccountFallsBackToStaging() {
        #expect(CloudConfiguration.launchAccount(chosen: .nightly, nightlyIsRunning: { true }) == .nightly)
        #expect(CloudConfiguration.launchAccount(chosen: .nightly, nightlyIsRunning: { false }) == .staging)
        #expect(CloudConfiguration.launchAccount(chosen: .staging, nightlyIsRunning: { true }) == .staging)
    }
}
