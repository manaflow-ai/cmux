import Testing
@testable import CmuxFoundation

@Suite struct SentryBuildIdentityPolicyTests {
    private static let base = "com.cmuxterm.app"

    @Test(arguments: [
        "com.cmuxterm.app",
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.nightly.rc1",
        "com.cmuxterm.app.staging",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.debug.snmsc",
        " com.cmuxterm.app "
    ])
    func allowsCmuxBuildIdentities(_ bundleIdentifier: String) {
        #expect(SentryBuildIdentityPolicy(
            bundleIdentifier: bundleIdentifier,
            trustedBaseBundleIdentifier: Self.base
        ).allowsTelemetry)
    }

    @Test(arguments: [
        "mosaic.com.emergent.app",
        "com.emergent.mosaic",
        "com.cmuxterm.application",
        "com.cmuxterm",
        "org.example.cmux",
        "",
        " "
    ])
    func deniesForeignBuildIdentities(_ bundleIdentifier: String) {
        #expect(!SentryBuildIdentityPolicy(
            bundleIdentifier: bundleIdentifier,
            trustedBaseBundleIdentifier: Self.base
        ).allowsTelemetry)
    }

    @Test func deniesMissingBuildIdentity() {
        #expect(!SentryBuildIdentityPolicy(
            bundleIdentifier: nil,
            trustedBaseBundleIdentifier: Self.base
        ).allowsTelemetry)
    }
}
