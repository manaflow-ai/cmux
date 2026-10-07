import CmuxUpdater
import Foundation
import Testing
@testable import CmuxNextUpdater

@Suite struct SystemVersionTests {
    @Test func parsesAndOrders() throws {
        #expect(SystemVersion("26") == SystemVersion(major: 26))
        #expect(SystemVersion("26.0") == SystemVersion("26.0.0"))
        #expect(try #require(SystemVersion("15.6.1")) < #require(SystemVersion("26.0")))
        #expect(try #require(SystemVersion("14.10")) > #require(SystemVersion("14.9")))
        #expect(SystemVersion("26.0")?.description == "26.0")
        #expect(SystemVersion("15.6.1")?.description == "15.6.1")
    }

    @Test func rejectsJunk() {
        for text in ["", "26.", "a.b", "26.0.0.1", "-1", "26 .0", "２６"] {
            #expect(SystemVersion(text) == nil, "\(text)")
        }
    }
}

@Suite struct UpdateTrackTests {
    @Test func releaseBundlesFollowTheirFeed() {
        #expect(AppcastFixtures.identity().track == .stable)
        let nightly = AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", feed: "https://files.cmux.com/nightly/appcast.xml")
        #expect(nightly.track == .nightly)
        #expect(AppcastFixtures.identity(feed: "https://files.cmux.com/rc/appcast.xml").track == .rc)
        // No feed in Info.plist falls back to the stable latest-release feed.
        #expect(AppcastFixtures.identity(feed: nil).track == .stable)
    }

    @Test func taggedDevAndStagingBuildsAreDevelopment() {
        for bundle in ["com.cmuxterm.app.debug", "com.cmuxterm.app.debug.updtr", "com.cmuxterm.app.staging", "com.cmuxterm.app.staging.x"] {
            #expect(AppcastFixtures.identity(bundle: bundle).track == .development, "\(bundle)")
        }
        #expect(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debugger").track == .stable)
    }

    @Test func nightlyFeedIsPerArchitectureStableIsNot() {
        let nightly = AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly", feed: "https://files.cmux.com/nightly/appcast.xml")
        #expect(nightly.feed(architecture: .arm64).url == "https://files.cmux.com/nightly/appcast-arm64.xml")
        #expect(nightly.feed(architecture: .x86_64).url == "https://files.cmux.com/nightly/appcast-x86_64.xml")
        let stable = AppcastFixtures.identity()
        #expect(stable.feed(architecture: .arm64).url == "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml")
    }

    /// A cmux-next NIGHTLY (same bundle id as main's NIGHTLY) is on the nightly track but
    /// reads only its own per-architecture feed, never main's NIGHTLY feed.
    @Test func nightlyNextBuildReadsOnlyItsOwnFeed() {
        let next = AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly",
                                            feed: "https://files-next.cmux.com/nightly-next/appcast.xml")
        #expect(next.track == .nightly)
        #expect(next.feed(architecture: .arm64).url == "https://files-next.cmux.com/nightly-next/appcast-arm64.xml")
        #expect(next.feed(architecture: .x86_64).url == "https://files-next.cmux.com/nightly-next/appcast-x86_64.xml")
        for architecture in [UpdateHostArchitecture.arm64, .x86_64] {
            #expect(!next.feed(architecture: architecture).url.hasPrefix("https://files.cmux.com/"))
        }
    }

    @Test func sparkleRunsOnlyForSignedReleaseBuilds() {
        #expect(AppcastFixtures.identity().sparkleDisabledReason(managedPolicyDisablesUpdates: false) == nil)
        #expect(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.t").sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .developmentBuild)
        #expect(AppcastFixtures.identity(key: false).sparkleDisabledReason(managedPolicyDisablesUpdates: false) == .missingPublicKey)
        #expect(AppcastFixtures.identity().sparkleDisabledReason(managedPolicyDisablesUpdates: true) == .managedPolicy)
    }

    @Test func infoDictionaryRejectsUnsubstitutedKey() {
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.cmuxterm.app", "CFBundleVersion": "107", "CFBundleShortVersionString": "0.65.0",
            "LSMinimumSystemVersion": "26.0", "SUPublicEDKey": "$(SPARKLE_PUBLIC_KEY)",
        ]
        let identity = UpdateBuildIdentity(infoDictionary: info)
        #expect(!identity.hasPublicKey)
        #expect(identity.minimumSystemVersion == SystemVersion(major: 26))
        #expect(identity.build == "107")
    }

    @Test func channelSwitchParityWithLegacyApp() {
        #expect(AppcastFixtures.identity().channelSwitchTarget == .nightly)
        #expect(AppcastFixtures.identity(bundle: "com.cmuxterm.app.nightly").channelSwitchTarget == .stable)
        #expect(AppcastFixtures.identity(bundle: "com.cmuxterm.app.debug.t").channelSwitchTarget == nil)
    }
}
