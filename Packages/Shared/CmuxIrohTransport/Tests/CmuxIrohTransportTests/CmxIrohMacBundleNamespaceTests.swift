import CMUXMobileCore
import Foundation
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

    /// The phone checks a push key-exchange reply against the namespace the
    /// Mac advertised in its host status. The two use different forms, so a
    /// drift between them makes every exchange fail and every push
    /// undecryptable.
    @Test func pushKeyExchangeReplyMatchesTheAdvertisedNamespace() throws {
        func reply(macBuildID: String) -> MobilePhonePushKeyExchangeResponse {
            MobilePhonePushKeyExchangeResponse(
                descriptor: MobilePhonePushPublicKeyDescriptor(
                    installationID: "mac-install",
                    keyID: "mac-key",
                    publicKey: Data(repeating: 1, count: 32)
                ),
                accountID: "account",
                macDeviceID: "device",
                macInstanceTag: "nightly",
                macBuildID: macBuildID
            )
        }
        for bundle in ["com.cmuxterm.app", "com.cmuxterm.app.nightly", "com.cmuxterm.app.debug.Push-Tag"] {
            let namespace = try #require(CmxIrohMacBundleNamespace(bundleIdentifier: bundle))
            #expect(reply(macBuildID: bundle).matchesMacClientNamespace(namespace.rawValue))
            #expect(!reply(macBuildID: bundle).matchesMacClientNamespace(bundle))
        }
        let stable = try #require(CmxIrohMacBundleNamespace(bundleIdentifier: "com.cmuxterm.app"))
        #expect(!reply(macBuildID: "com.cmuxterm.app.nightly").matchesMacClientNamespace(stable.rawValue))
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
