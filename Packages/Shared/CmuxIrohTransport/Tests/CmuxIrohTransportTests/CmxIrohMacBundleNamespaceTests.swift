import Testing
@testable import CmuxIrohTransport

@Suite
struct CmxIrohMacBundleNamespaceTests {
    @Test func exactBundlesRemainDistinctEvenWhenTheirTagsMatch() throws {
        let stable = try #require(
            CmxIrohMacBundleNamespace(
                bundleIdentifier: "com.cmuxterm.app"
            )
        )
        let staging = try #require(
            CmxIrohMacBundleNamespace(
                bundleIdentifier: "com.cmuxterm.app.staging"
            )
        )

        #expect(stable.rawValue == "mac:com.cmuxterm.app")
        #expect(staging.rawValue == "mac:com.cmuxterm.app.staging")
        #expect(stable != staging)
    }

    @Test func invalidOrMissingBundleIdentityFailsClosed() {
        #expect(CmxIrohMacBundleNamespace(bundleIdentifier: nil) == nil)
        #expect(CmxIrohMacBundleNamespace(bundleIdentifier: "") == nil)
        #expect(
            CmxIrohMacBundleNamespace(
                bundleIdentifier: "com.cmuxterm.app:other"
            ) == nil
        )
    }
}
