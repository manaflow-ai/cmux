import Testing
@testable import CmuxMobileShell

struct MacBuildChannelTests {
    @Test func devTagWinsAndIsShown() {
        // A tagged reload.sh build sets CMUX_TAG; any non-"default" tag is a DEV
        // build and the tag is what's worth showing — regardless of bundle id.
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.debug.teams", tag: "teams") == "DEV · teams")
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app", tag: "my-tag") == "DEV · my-tag")
    }

    @Test func channelFromBundleComponentWhenNoDevTag() {
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app", tag: "default") == "Stable")
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.nightly", tag: "default") == "Nightly")
        // Tagged channel builds append a further .slug — match the COMPONENT, not a suffix.
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.nightly.my-feature", tag: "default") == "Nightly")
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.staging.feat", tag: nil) == "Staging")
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.debug", tag: "default") == "DEV")
    }

    @Test func handlesFutureReleaseCandidateChannel() {
        // The RC desktop build (com.cmuxterm.app.rc) is handled ahead of time.
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.rc", tag: "default") == "RC")
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.rc.candidate1", tag: nil) == "RC")
    }

    @Test func canonicalTagIdentifiesAppWithoutLivePresenceBundleMetadata() {
        let channel = MacBuildChannel()

        #expect(channel.label(bundleID: nil, tag: "default") == "Stable")
        #expect(channel.label(bundleID: nil, tag: "nightly") == "Nightly")
        #expect(channel.label(bundleID: nil, tag: "staging") == "Staging")
        #expect(channel.label(bundleID: nil, tag: "rc") == "RC")
        #expect(channel.label(bundleID: nil, tag: "future-one") == "DEV · future-one")
        #expect(channel.appDisplayName(bundleID: nil, tag: "default") == "cmux")
        #expect(channel.appDisplayName(bundleID: nil, tag: "nightly") == "cmux Nightly")
        #expect(channel.appDisplayName(bundleID: nil, tag: "future-one") == "cmux DEV future-one")
    }

    @Test func nilWhenNotIdentifiable() {
        #expect(MacBuildChannel().label(bundleID: nil, tag: nil) == nil)
        #expect(MacBuildChannel().label(bundleID: "com.example.other", tag: "default") == nil)
        // Unknown future channel component is not guessed at.
        #expect(MacBuildChannel().label(bundleID: "com.cmuxterm.app.beta", tag: "default") == nil)
    }
}
