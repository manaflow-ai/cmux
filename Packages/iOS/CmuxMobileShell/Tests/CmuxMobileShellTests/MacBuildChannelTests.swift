import Testing
@testable import CmuxMobileShell

struct MacBuildChannelTests {
    @Test func devTagWinsAndIsShown() {
        // A tagged reload.sh build sets CMUX_TAG; any non-"default" tag is a DEV
        // build and the tag is what's worth showing — regardless of bundle id.
        #expect(MacBuildChannel.label(bundleID: "dev.cmux.mac.teams", tag: "teams") == "DEV · teams")
        #expect(MacBuildChannel.label(bundleID: "com.cmuxterm.app", tag: "my-tag") == "DEV · my-tag")
    }

    @Test func channelFromBundleSuffixWhenNoDevTag() {
        #expect(MacBuildChannel.label(bundleID: "com.cmuxterm.app", tag: "default") == "Stable")
        #expect(MacBuildChannel.label(bundleID: "com.cmuxterm.app.nightly", tag: "default") == "Nightly")
        #expect(MacBuildChannel.label(bundleID: "com.cmuxterm.app.rc", tag: "default") == "RC")
        #expect(MacBuildChannel.label(bundleID: "com.cmuxterm.app.staging", tag: nil) == "Staging")
        #expect(MacBuildChannel.label(bundleID: "dev.cmux.mac", tag: "default") == "DEV")
    }

    @Test func nilWhenNotIdentifiable() {
        #expect(MacBuildChannel.label(bundleID: nil, tag: "default") == nil)
        #expect(MacBuildChannel.label(bundleID: nil, tag: nil) == nil)
        #expect(MacBuildChannel.label(bundleID: "com.example.other", tag: "default") == nil)
    }
}
