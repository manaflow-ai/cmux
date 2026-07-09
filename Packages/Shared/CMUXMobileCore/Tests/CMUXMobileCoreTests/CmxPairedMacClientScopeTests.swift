import Foundation
import Testing

@testable import CMUXMobileCore

@Suite struct CmxPairedMacClientScopeTests {
    @Test func matchingTaggedMacAndIOSBuildsShareOneVersionedScope() throws {
        let ios = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: "ignored",
            bundleIdentifier: "dev.cmux.ios.feature"
        ))
        let mac = try #require(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "feature"],
            bundleIdentifier: "com.cmuxterm.app.debug.feature"
        ))

        #expect(ios == mac)
        #expect(ios.value == "feature")
        #expect(ios.serializedScope == "cmux-dev:v2:ZmVhdHVyZQ")
    }

    @Test func releaseAndUntaggedBuildsStayUnscoped() {
        #expect(CmxPairedMacClientScope.currentIOS(
            devTag: "stray",
            bundleIdentifier: "com.cmuxterm.app",
            isDebugBuild: false
        ) == nil)
        #expect(CmxPairedMacClientScope.currentIOS(
            devTag: "stray",
            bundleIdentifier: "dev.cmux.app.beta",
            isDebugBuild: false
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "stray"],
            bundleIdentifier: "com.cmuxterm.app"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "default"],
            bundleIdentifier: "com.cmuxterm.app.debug"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "feature"],
            bundleIdentifier: "com.example.cmux.debug.feature"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: [:],
            bundleIdentifier: "com.cmuxterm.app.debug.feature"
        ) == nil)
    }

    @Test func explicitDefaultTaggedBuildsStayStrictlyScoped() throws {
        let ios = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "dev.cmux.ios.default"
        ))
        let legacyIOSBundle = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: "default",
            bundleIdentifier: "dev.cmux.ios"
        ))
        let mac = try #require(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "default"],
            bundleIdentifier: "com.cmuxterm.app.debug.default"
        ))

        #expect(ios == mac)
        #expect(legacyIOSBundle == mac)
        #expect(ios.serializedScope == "cmux-dev:v2:ZGVmYXVsdA")
        #expect(CmxPairedMacClientScope.pairedMacBackupPath == "/v2/sync/paired-macs")
    }

    @Test func everyDebugIOSIdentityGetsAStrictScope() throws {
        let custom = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: "custom-tag",
            bundleIdentifier: "com.example.custom-debug",
            isDebugBuild: true
        ))
        let fallback = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "com.example.custom-debug",
            isDebugBuild: true
        ))

        #expect(custom.value == "custom-tag")
        #expect(fallback.value == "default")
    }

    @Test func scopeAcceptsOnlyItsMatchingMacPresenceTag() throws {
        let scope = try #require(CmxPairedMacClientScope("feature"))

        #expect(scope.matchesMacInstance(
            tag: "feature",
            bundleIdentifier: "com.cmuxterm.app.debug.feature"
        ))
        #expect(!scope.matchesMacInstance(
            tag: "other",
            bundleIdentifier: "com.cmuxterm.app.debug.other"
        ))
        #expect(!scope.matchesMacInstance(tag: "default", bundleIdentifier: "com.cmuxterm.app"))
    }
}
