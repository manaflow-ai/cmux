import CmuxNextSettings
@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// Switching channels in place, both ways. Picking a faster ring checks at once (its newer build
/// downloads and waits for one restart); picking a slower ring the running build is not on goes
/// back into the build this Mac kept from it, or the running build stays until the ring passes it.
@MainActor @Suite struct RingReturnTests {
    private static func kept(_ build: String) -> KeptVersion {
        KeptVersion(build: build, shortVersion: "1.0.0-nightly.\(build)", bundle: URL(fileURLWithPath: "/kept/\(build)/cmux.app"),
                    storeSchemas: [:], teamID: "TEAM")
    }

    private static func item(_ build: String, _ channel: String) -> AppcastItem {
        AppcastItem(version: build, sparkleChannel: channel)
    }

    /// Nightly's view of a feed where 500 is a Dev build and 300 the newest promoted one.
    private static let nightlyOffered = [item("300", "cmux-next"), item("200", "cmux-next")]

    @Test func aDevBuildNightlyHasNotReachedGoesBackToTheNewestKeptNightlyBuild() {
        let way = RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: [],
                                    kept: [Self.kept("450"), Self.kept("300"), Self.kept("200")])
        // 450 was a Dev build: not on Nightly, so the way back skips it.
        #expect(way == .goBack(Self.kept("300")))
    }

    @Test func aKeptBuildTheCanaryPassedCountsAsNightlyAfterItLeavesTheFeed() {
        let way = RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: ["120"],
                                    kept: [Self.kept("450"), Self.kept("120")])
        #expect(way == .goBack(Self.kept("120")))
    }

    @Test func aPulledBuildIsNeverTheWayBackEvenWithItsCanaryPass() {
        let way = RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: ["320", "300"],
                                    pulled: ["320"], kept: [Self.kept("320"), Self.kept("300")])
        #expect(way == .goBack(Self.kept("300")))
        #expect(RingReturn.decide(installedBuild: "500", offered: [Self.item("200", "cmux-next")], promoted: ["320"],
                                  pulled: ["320"], kept: [Self.kept("320")]) == .waits)
    }

    @Test func nothingKeptOnTheRingWaitsForItToPassTheRunningBuild() {
        #expect(RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: [],
                                  kept: [Self.kept("450")]) == .waits)
        #expect(RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: [], kept: []) == .waits)
    }

    @Test func theRunningBuildOnTheRingOrBehindItTakesTheNormalUpdatePath() {
        // On the ring (in the feed, or promoted since): nothing to go back to.
        #expect(RingReturn.decide(installedBuild: "300", offered: Self.nightlyOffered, promoted: [], kept: [Self.kept("200")]) == .none)
        #expect(RingReturn.decide(installedBuild: "500", offered: Self.nightlyOffered, promoted: ["500"], kept: [Self.kept("300")]) == .none)
        // The ring has a newer build: Sparkle offers it.
        #expect(RingReturn.decide(installedBuild: "250", offered: Self.nightlyOffered, promoted: [], kept: [Self.kept("200")]) == .none)
    }

    @Test func theCardsSwitchCarriesTheGoBackButtonOrTheWaitLine() throws {
        let back = try #require(UpdaterService.switchState(ring: .nightly, way: .goBack(Self.kept("300")),
                                                          installedVersion: "1.0.0-nightly.500") as? [String: Any])
        #expect(back["build"] as? String == "300")
        #expect(back["action"] as? String == "Go Back to Nightly")
        #expect(back["detail"] as? String == "Restarts once into 1.0.0-nightly.300, kept on this Mac. Settings and sessions stay.")
        let waits = try #require(UpdaterService.switchState(ring: .nightly, way: .waits,
                                                           installedVersion: "1.0.0-nightly.500") as? [String: Any])
        #expect(waits["action"] is NSNull)
        #expect(waits["detail"] as? String == "This Mac stays on 1.0.0-nightly.500 until Nightly reaches a newer build.")
        #expect(UpdaterService.switchState(ring: .nightly, way: .none, installedVersion: "1") is NSNull)
    }

    struct StaticFeed: AppcastFetching {
        let xml: String
        func fetch(_ url: URL) async throws -> Data { Data(xml.utf8) }
    }

    /// The launch's channel is applied without a check; the person's later pick checks that ring at
    /// once (here the read-only probe, as on a DEV build where Sparkle never runs).
    @Test func pickingAChannelChecksItAtOnceButTheLaunchValueDoesNot() async throws {
        let feed = """
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>cmux NEXT</title>
        <item><title>nightly</title><sparkle:version>300</sparkle:version><sparkle:channel>cmux-next</sparkle:channel></item>
        <item><title>dev</title><sparkle:version>500</sparkle:version><sparkle:channel>cmux-next-dev</sparkle:channel></item>
        </channel></rss>
        """
        let defaults = try #require(UserDefaults(suiteName: "RingReturnTests.\(UUID().uuidString)"))
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.debug.ring-return", shortVersion: "1.0.0",
                                           build: "100", minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml",
                                           hasPublicKey: false)
        let updater = UpdaterService(identity: identity, policy: ManagedUpdatePolicy { false },
                                     prober: UpdateProber(fetcher: StaticFeed(xml: feed), architecture: .arm64),
                                     defaults: defaults, enableSparkle: false, recordsUpdates: false)
        updater.announcementsFetch = false
        updater.follow(ring: "nightly")
        #expect(!updater.isProbing)
        updater.follow(ring: "dev")
        // The pick started the check itself; this only waits for it.
        #expect(updater.isProbing)
        _ = await updater.probe().value
        guard case .updateAvailable(let item) = updater.lastProbe?.outcome else {
            Issue.record("\(String(describing: updater.lastProbe))")
            return
        }
        #expect(item.version == "500")
    }
}
