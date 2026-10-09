@testable import CmuxNextCloud
import Testing

/// cx-t2rz: Debug builds list, create and connect Cloud machines through the
/// Cloud app server (the cmux-next API Worker) by default; `/api/vm` stays
/// only behind `CMUX_CLOUD_LINK=legacy` and in release builds.
struct CloudLinkSourceTests {
    static func resolve(_ env: [String: String], debug: Bool = true) -> CloudConfiguration {
        CloudConfiguration.resolve(bundleID: "com.cmuxterm.app.debug.t", bundled: [:], process: env, isDebugBuild: debug)
    }

    @Test func aDebugBuildUsesTheAppServerByDefault() {
        #expect(Self.resolve([:]).linkSource == .appServer)
        #expect(Self.resolve(["CMUX_DEV_BACKEND_URL": "https://dev.example.ts.net:3865"]).linkSource == .appServer)
        #expect(Self.resolve(["CMUX_CLOUD_LINK": "app"]).linkSource == .appServer)
    }

    @Test func legacyIsAnExplicitOptOut() {
        #expect(Self.resolve(["CMUX_CLOUD_LINK": "legacy"]).linkSource == .legacy)
        #expect(Self.resolve(["CMUX_CLOUD_LINK": "LEGACY"]).linkSource == .legacy)
    }

    @Test func releaseBuildsKeepTheirPath() {
        #expect(Self.resolve([:], debug: false).linkSource == .legacy)
    }
}
