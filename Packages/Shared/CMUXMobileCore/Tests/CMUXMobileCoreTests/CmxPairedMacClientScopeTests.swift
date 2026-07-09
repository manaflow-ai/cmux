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
            bundleIdentifier: "com.cmuxterm.app"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "stray"],
            bundleIdentifier: "com.cmuxterm.app"
        ) == nil)
        #expect(CmxPairedMacClientScope.currentMac(
            environment: ["CMUX_TAG": "default"],
            bundleIdentifier: "com.cmuxterm.app.debug"
        ) == nil)
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
