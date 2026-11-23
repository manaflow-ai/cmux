import CMUXAuthCore
import CmuxAuthRuntime
@testable import CmuxNextCloud
import Foundation
import Testing

struct CloudConfigurationSignedDEVTests {
    @Test func runtimeSelectionUsesTheBackendValuesWithoutBuildPins() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
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
        #expect(config.isProductionAuth)
        #expect(config.apiBaseURL == config.runtimeSelection?.apiOrigin)
        #expect(config.ownerAPIBaseURL() == config.apiBaseURL)
    }

    @Test func debugBuildUsesItsSelectedRuntimeOrigin() {
        let config = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: ["CMUX_VM_API_BASE_URL": "https://debug.fixture.invalid"], process: [:], isDebugBuild: true)
        #expect(config.ownerAPIBaseURL() == URL(string: "https://debug.fixture.invalid"))
    }
    /// Signed NEXT DEV is a DEV build like any other: on production as on staging it has its own build space and
    /// its own Keychain session (seeded by `scripts/cmux-next/dev-signin-token.py`), and never takes a running
    /// NIGHTLY's (no `ImportingTokenStore`, no memory-only store fed from NIGHTLY).
    @Test func signedDEVOnProductionKeepsItsOwnSessionAndSpace() throws {
        let staging = CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.next", bundled: [:], process: [:], isDebugBuild: false)
        var selection = try #require(staging.runtimeSelection)
        selection.name = "prod"
        let production = CloudConfiguration.from(selection: selection, bundleID: "com.cmuxterm.app.debug.next",
                                                 bundled: [:], process: [:], isDebugBuild: false)
        #expect(production.isProductionAuth)
        #expect(production.callbackURL.absoluteString == "cmux-next-dev://auth-callback")
        for configuration in [staging, production] {
            #expect(configuration.buildSpace.space?.headerValue == "dev:next")
            #expect(configuration.keychainService.hasPrefix("com.cmuxterm.app.debug.next.auth."))
            let store = CloudAuth.tokenStore(configuration: configuration)
            #expect(!(store is ImportingTokenStore))
            #expect(!(store is MemoryStackTokenStore))
        }
    }
}
