@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The tip app (Leo 2026-10-24: "a separate app where, like, that is able to just track the latest
/// tip") is cmux NEXT DEV as main's publisher ships it: bundle id `com.cmuxterm.app.debug.next`
/// with `SUFeedURL` stamped to the tip feed. Only that pair runs Sparkle; every other DEV and
/// staging build stays a development build that never installs updates.
@Suite struct TipAppTrackTests {
    nonisolated static let tipFeed = "https://files.cmux.com/nightly-next/tip/appcast-arm64.xml"
    nonisolated static let stableFeed = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml"

    static func identity(_ bundleIdentifier: String, feed: String?, hasPublicKey: Bool = true) -> UpdateBuildIdentity {
        var info: [String: Any] = ["CFBundleIdentifier": bundleIdentifier, "CFBundleShortVersionString": "0.1.0",
                                   "CFBundleVersion": "24950001", "LSMinimumSystemVersion": "26.0"]
        if let feed { info["SUFeedURL"] = feed }
        if hasPublicKey { info["SUPublicEDKey"] = "dGVzdC1rZXktbm90LXJlYWwtYnV0LW5vbi1lbXB0eQ==" }
        return UpdateBuildIdentity(infoDictionary: info)
    }

    @Test func theTipStampedDevAppIsNightlyAndRunsSparkle() {
        let tip = Self.identity("com.cmuxterm.app.debug.next", feed: Self.tipFeed)
        #expect(tip.isTipBuild)
        #expect(tip.track == .nightly)
        #expect(tip.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == nil)
        // A managed DisableAutoUpdate still wins.
        #expect(tip.sparkleDisabledReason(managedPolicyDisablesUpdates: true) == .managedPolicy)
        // Resolves like cmux NEXT's nightly feed: per architecture, untagged items accepted.
        let feed = tip.feed(architecture: .arm64)
        #expect(feed.channel == .nightlyNext)
        #expect(feed.url == Self.tipFeed)
        #expect(tip.feed(architecture: .x86_64).url == Self.tipFeed)
        #expect(UpdateFeedResolver().resolve(infoFeedURL: "https://files.cmux.com/nightly-next/tip/appcast.xml").channel == .nightlyNext)
        // DEV has no NIGHTLY/stable counterpart to switch to.
        #expect(tip.channelSwitchTarget == nil)
    }

    @Test func theTipAppWithoutAKeyDoesNotRunSparkle() {
        let tip = Self.identity("com.cmuxterm.app.debug.next", feed: Self.tipFeed, hasPublicKey: false)
        #expect(tip.track == .nightly)
        #expect(tip.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .missingPublicKey)
    }

    /// `reload.sh --tag next` builds the same bundle id with the default (stable) feed.
    @Test(arguments: [Self.stableFeed, nil, "", "https://files-next.cmux.com/nightly-next/appcast-arm64.xml",
                      "https://files.cmux.com/nightly/appcast-arm64.xml", "https://example.com/nightly-next/tip/appcast-arm64.xml"])
    func theDevAppWithAnyOtherFeedStaysDevelopment(feed: String?) {
        let dev = Self.identity("com.cmuxterm.app.debug.next", feed: feed)
        #expect(!dev.isTipBuild)
        #expect(dev.track == .development)
        #expect(dev.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .developmentBuild)
    }

    @Test(arguments: ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.next.other", "com.cmuxterm.app.debug.nextx",
                      "com.cmuxterm.app.debug.tip", "com.cmuxterm.app.staging", "com.cmuxterm.app.staging.next"])
    func otherDevAndStagingBuildsWithTheTipFeedStayDevelopment(bundleIdentifier: String) {
        let other = Self.identity(bundleIdentifier, feed: Self.tipFeed)
        #expect(!other.isTipBuild)
        #expect(other.track == .development)
        #expect(other.sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .developmentBuild)
    }

    @Test func releaseAppsKeepTheirTracks() {
        #expect(Self.identity("com.cmuxterm.app.nightly", feed: "https://files.cmux.com/nightly/appcast-arm64.xml").track == .nightly)
        #expect(Self.identity("com.cmuxterm.app", feed: Self.stableFeed).track == .stable)
        // A release id reading the tip feed is not "the tip app", but its feed still classifies it.
        #expect(!Self.identity("com.cmuxterm.app.nightly.cmux-next", feed: Self.tipFeed).isTipBuild)
    }

    /// The service builds no Sparkle driver in tests (`enableSparkle: false`), so the reason it
    /// reports comes from the identity alone: none for the tip app, development for the rest.
    @MainActor @Test func theServiceReportsNoDisabledReasonOnlyForTheTipApp() {
        let defaults = UserDefaults(suiteName: "TipAppTrackTests.\(UUID().uuidString)")!
        let tip = UpdaterService(identity: Self.identity("com.cmuxterm.app.debug.next", feed: Self.tipFeed),
                                 policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false, recordsUpdates: false)
        #expect(tip.disabledReason == nil)
        let local = UpdaterService(identity: Self.identity("com.cmuxterm.app.debug.next", feed: Self.stableFeed),
                                   policy: ManagedUpdatePolicy { false }, defaults: defaults, enableSparkle: false, recordsUpdates: false)
        #expect(local.disabledReason == .developmentBuild)
    }
}
