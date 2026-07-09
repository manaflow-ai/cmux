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
        #expect(ios.matchingMacTag == "feature")
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
            bundleIdentifier: "com.cmuxterm.app.debug.default"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "default"],
            bundleIdentifier: "com.cmuxterm.app.debug.feature"
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

    @Test func debugFallbackIdentitiesAreDistinctAndCannotMatchMacs() throws {
        let base = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "dev.cmux.ios",
            isDebugBuild: true
        ))
        let custom = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "com.example.custom-debug",
            isDebugBuild: true
        ))
        let explicitDefault = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "dev.cmux.ios.default",
            isDebugBuild: true
        ))

        #expect(Set([base.serializedScope, custom.serializedScope, explicitDefault.serializedScope]).count == 3)
        for scope in [base, custom, explicitDefault] {
            #expect(scope.matchingMacTag == nil)
            #expect(!scope.matchesMacInstance(
                tag: "default",
                bundleIdentifier: "com.cmuxterm.app.debug.default"
            ))
        }
        #expect(CmxPairedMacClientScope("default") == nil)
        #expect(CmxPairedMacClientScope.pairedMacBackupPath == "/v2/sync/paired-macs")
    }

    @Test func everyDebugIOSIdentityGetsAStrictScope() throws {
        let custom = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: "Custom Tag",
            bundleIdentifier: "com.example.custom-debug",
            isDebugBuild: true
        ))
        let fallback = try #require(CmxPairedMacClientScope.currentIOS(
            devTag: nil,
            bundleIdentifier: "com.example.custom-debug",
            isDebugBuild: true
        ))

        #expect(custom.value == "custom-tag")
        #expect(custom.matchingMacTag == "custom-tag")
        #expect(custom.matchesMacInstance(
            tag: "custom-tag",
            bundleIdentifier: "com.cmuxterm.app.debug.custom-tag"
        ))
        #expect(fallback.matchingMacTag == nil)
        #expect(fallback.value != "default")
    }

    @Test func canonicalizesRawTagsLikeSharedReloadTooling() throws {
        #expect(try #require(CmxPairedMacClientScope("Feature Tag")).value == "feature-tag")
        #expect(try #require(CmxPairedMacClientScope("-n")).value == "n")
        #expect(CmxPairedMacClientScope("---") == nil)
        #expect(CmxPairedMacClientScope("default") == nil)
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
