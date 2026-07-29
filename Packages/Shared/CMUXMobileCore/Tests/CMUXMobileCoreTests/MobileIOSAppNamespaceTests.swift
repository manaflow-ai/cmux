import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct MobileIOSAppNamespaceTests {
    @Test(
        arguments: [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
            "dev.cmux.ios.feature-a",
            "dev.cmux.ios.feature-b",
        ]
    )
    func fullBundleIdentifierOwnsEveryNamespace(bundleIdentifier: String) throws {
        let namespace = try #require(
            MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        )

        #expect(namespace.bundleIdentifier == bundleIdentifier)
        #expect(
            namespace.keychainService(base: "com.cmuxterm.iroh.identity")
                == "com.cmuxterm.iroh.identity.\(bundleIdentifier)"
        )
        #expect(
            namespace.keychainAccessGroup(teamIdentifier: "7WLXT3NR37")
                == "7WLXT3NR37.\(bundleIdentifier)"
        )
        #expect(
            namespace.pairingURLScheme
                == "cmux-ios-\(bundleIdentifier)"
        )
    }

    @Test func appTypesAndDevTagsNeverShareServerOrCallbackScopes() throws {
        let bundleIdentifiers = [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
            "dev.cmux.ios.feature-a",
            "dev.cmux.ios.feature-b",
        ]
        let namespaces = try bundleIdentifiers.map {
            try #require(MobileIOSAppNamespace(bundleIdentifier: $0))
        }

        #expect(Set(namespaces.map(\.serverScope)).count == namespaces.count)
        #expect(Set(namespaces.map(\.pairingURLScheme)).count == namespaces.count)
        #expect(
            Set(
                namespaces.map {
                    $0.keychainService(base: "com.cmuxterm.iroh.identity")
                }
            ).count == namespaces.count
        )
    }

    @Test func rejectsMissingOrUnsafeBundleIdentifiers() {
        #expect(MobileIOSAppNamespace(bundleIdentifier: nil) == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "") == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "dev.cmux.ios.*") == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "dev cmux ios") == nil)
    }
}
