import CmuxNextCloud
import Foundation
import Testing

/// Which Cloud link a build uses (`CloudConfiguration.linkSource`): a Debug build on a staging or
/// development backend takes the app server, whose Worker makes machines that hold agent chat tabs
/// (`cmux cloud start-session` was refused on the classic `/api/vm` machines); production and a
/// local-only backend keep the legacy link; `CMUX_NEXT_CLOUD_LINK` / `CMUX_CLOUD_LINK` pick either.
struct CloudConfigurationLinkSourceTests {
    static let stagingOrigin = "https://cmux-staging.vercel.app"
    /// What the HQ capture fixture bakes into a DEV build's copy (cloud_fixture.BACKEND_KEYS).
    static let staging = ["CMUX_API_BASE_URL": stagingOrigin, "CMUX_VM_API_BASE_URL": stagingOrigin,
                          "CMUX_AUTH_WWW_ORIGIN": stagingOrigin, "CMUX_WWW_ORIGIN": stagingOrigin]

    static func resolve(bundled: [String: String] = [:], process: [String: String] = [:], debug: Bool = true) -> CloudConfiguration {
        CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.link-test", bundled: bundled, process: process, isDebugBuild: debug)
    }

    static func stagingAnd(_ extra: [String: String]) -> [String: String] { staging.merging(extra) { $1 } }

    static func isDevelopment(_ configuration: CloudConfiguration) -> Bool {
        if case .development = configuration.backend { return true }
        return false
    }

    static func isLocalOnly(_ configuration: CloudConfiguration) -> Bool {
        if case .localOnly = configuration.backend { return true }
        return false
    }

    @Test func aDebugBuildOnStagingUsesTheAppServer() {
        let configuration = Self.resolve(bundled: Self.staging)
        #expect(Self.isDevelopment(configuration))
        #expect(configuration.apiBaseURL.absoluteString == Self.stagingOrigin)
        #expect(!configuration.isProductionAuth)
        #expect(configuration.linkSource == .appServer)
    }

    @Test func aDebugBuildOnADevelopmentStackUsesTheAppServer() {
        let configuration = Self.resolve(bundled: ["CMUX_DEV_BACKEND_URL": "https://dev-stack.standin.invalid"])
        #expect(Self.isDevelopment(configuration))
        #expect(configuration.linkSource == .appServer)
    }

    @Test func aLocalOnlyBackendKeepsTheLegacyLink() {
        let unset = Self.resolve()
        #expect(Self.isLocalOnly(unset))
        #expect(unset.linkSource == .legacy)
        let loopback = Self.resolve(bundled: ["CMUX_API_BASE_URL": "http://127.0.0.1:9100"])
        #expect(Self.isLocalOnly(loopback))
        #expect(loopback.linkSource == .legacy)
    }

    @Test func productionKeepsTheLegacyLink() {
        // A Release build ignores the bundle's backend and every link override.
        let environments: [[String: String]] = [[:], Self.staging, Self.stagingAnd(["CMUX_CLOUD_LINK": "app"])]
        for environment in environments {
            let release = Self.resolve(bundled: environment, process: ["CMUX_NEXT_CLOUD_LINK": "app"], debug: false)
            #expect(release.backend == .production)
            #expect(release.linkSource == .legacy)
        }
        // A Debug build on production auth is production too.
        let productionAuth = Self.resolve(bundled: Self.stagingAnd(["CMUX_AUTH_ENVIRONMENT": "production"]))
        #expect(productionAuth.backend == .production)
        #expect(productionAuth.linkSource == .legacy)
    }

    @Test func legacyOverridesTheStagingDefault() {
        #expect(Self.resolve(bundled: Self.stagingAnd(["CMUX_CLOUD_LINK": "legacy"])).linkSource == .legacy)
        #expect(Self.resolve(bundled: Self.staging, process: ["CMUX_NEXT_CLOUD_LINK": "Legacy"]).linkSource == .legacy)
    }

    @Test func appOverridesTheLocalOnlyDefault() {
        #expect(Self.resolve(process: ["CMUX_NEXT_CLOUD_LINK": "app"]).linkSource == .appServer)
        #expect(Self.resolve(bundled: ["CMUX_CLOUD_LINK": "APP"]).linkSource == .appServer)
    }

    @Test func theNextKeyWinsOverTheBakedKey() {
        // CMUX_NEXT_CLOUD_LINK is read before CMUX_CLOUD_LINK.
        #expect(Self.resolve(bundled: Self.stagingAnd(["CMUX_CLOUD_LINK": "app"]), process: ["CMUX_NEXT_CLOUD_LINK": "legacy"]).linkSource == .legacy)
        #expect(Self.resolve(bundled: ["CMUX_CLOUD_LINK": "legacy"], process: ["CMUX_NEXT_CLOUD_LINK": "app"]).linkSource == .appServer)
    }

    @Test func anUnknownValueKeepsTheBackendDefault() {
        #expect(Self.resolve(bundled: Self.stagingAnd(["CMUX_CLOUD_LINK": "1"])).linkSource == .appServer)
        #expect(Self.resolve(process: ["CMUX_NEXT_CLOUD_LINK": "yes"]).linkSource == .legacy)
    }
}
