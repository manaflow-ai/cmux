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
        let config = CloudConfiguration.resolve(bundleID: bundleID, bundled: ["CMUX_CLOUD_LINK": "app"], process: [:], isDebugBuild: false)
        #expect(config.linkSource == .legacy)
        #expect(config.isProductionAuth)
        #expect(config.apiBaseURL.absoluteString == "https://cmux.com")
        #expect(config.ownerAPIBaseURL(environment: [:]).absoluteString == "https://cloud-api.cmux.dev")
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
}
