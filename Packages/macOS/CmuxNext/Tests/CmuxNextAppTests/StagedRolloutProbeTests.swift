import CmuxUpdater
@testable import CmuxNextUpdater
import Foundation
import Testing

/// A staged stable rollout (docs/cmux-next/release-rollout.md) reaches only its share of installs. cmux's
/// own feed reads (the probe behind the update circle, the sheet, the changelog, and the swap of a waiting
/// update for a newer one) must follow the same stage as Sparkle's scheduled check, or an install outside
/// the stage is shown the build, and the waiting-update swap downloads it there with a check Sparkle does
/// not hold.
@MainActor @Suite(.serialized) struct StagedRolloutProbeTests {
    /// Build 500 at `percent` on the Dev ring, beside Nightly 300.
    static func feed(percent: String) -> String {
        UpdateStagedYieldsToNewerTests.feed()
            .replacingOccurrences(of: "<sparkle:channel>cmux-next-dev</sparkle:channel>",
                                  with: "<sparkle:channel>cmux-next-dev</sparkle:channel><cmux:rolloutPercent>\(percent)</cmux:rolloutPercent>")
            .replacingOccurrences(of: "<rss ", with: "<rss xmlns:cmux=\"\(StagedRollout.namespace)\" ")
    }

    @Test func theParserReadsTheItemsPercentage() throws {
        let items = try AppcastParser.parse(Data(Self.feed(percent: "5").utf8))
        #expect(items.first { $0.version == "500" }?.rolloutPercent == "5")
        #expect(items.first { $0.version == "300" }?.rolloutPercent == nil)
    }

    /// The person installed nothing and checked nothing: a scheduled probe while build 300 waits.
    @Test func aHaltedBuildDoesNotReplaceTheWaitingUpdate() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "dev", feed: Self.feed(percent: "0"))
        h.rig.advance(by: .seconds(UpdateStagedYieldsToNewerTests.interval))
        h.rig.fireAtNow()
        try await UpdateStagedYieldsToNewerTests().settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0, "a halted build replaced the waiting update")
        #expect(h.sparkle.backgroundChecks == 0)
        let outcome = try #require(h.updater.lastProbe?.outcome)
        if case .updateAvailable(let item) = outcome { Issue.record("the probe shows \(item.version) as an update") }
    }

    /// Nightly 300 waits, Dev 400 is open to all, Dev 500 is halted. Sparkle picks the newest
    /// allowed item (500) and holds it; it never falls back to 400. The probe must agree, or the
    /// swap cancels 300 for 400 and its Sparkle check, which the hold does not cover, downloads 500.
    static func fallbackFeed() -> String {
        Self.feed(percent: "0").replacingOccurrences(of: "<item><title>dev</title>", with:
            "<item><title>open</title><sparkle:version>400</sparkle:version><sparkle:channel>cmux-next-dev</sparkle:channel></item><item><title>dev</title>")
    }

    @Test func aHaltedNewestBuildIsNotSteppedAroundToAnOlderOne() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "dev", feed: Self.fallbackFeed())
        h.rig.advance(by: .seconds(UpdateStagedYieldsToNewerTests.interval))
        h.rig.fireAtNow()
        try await UpdateStagedYieldsToNewerTests().settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0, "the probe stepped around the halted newest build")
        #expect(h.sparkle.backgroundChecks == 0)
        let outcome = try #require(h.updater.lastProbe?.outcome)
        if case .updateAvailable(let item) = outcome { Issue.record("the probe offers \(item.version)") }
    }

    /// An emptied element is kept as written: a broken value, which Sparkle holds (StagedRollout.percent("") is nil).
    @Test func theParserKeepsAnEmptiedPercentage() throws {
        let items = try AppcastParser.parse(Data(Self.feed(percent: "").utf8))
        #expect(items.first { $0.version == "500" }?.rolloutPercent == "")
    }

    @Test func anEmptiedPercentageDoesNotReplaceTheWaitingUpdate() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "dev", feed: Self.feed(percent: ""))
        h.rig.advance(by: .seconds(UpdateStagedYieldsToNewerTests.interval))
        h.rig.fireAtNow()
        try await UpdateStagedYieldsToNewerTests().settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 0, "an emptied percentage replaced the waiting update")
    }

    /// A held newest build that needs a newer macOS is not named either: the install is outside its stage.
    @Test func aHeldBuildIsNotNamedAsNeedingANewerMacOS() throws {
        var prober = UpdateProber(fetcher: Feed(xml: ""), architecture: .arm64)
        prober.rollout = StagedRollout(seed: 1)
        let floor = try #require(SystemVersion("99.0"))
        let item = AppcastItem(version: "500", minimumSystemVersion: floor, rolloutPercent: "0")
        #expect(prober.held(.requiresNewerSystem(item, required: floor)) == .upToDate(latest: nil))
        #expect(prober.held(.updateAvailable(item)) == .upToDate(latest: nil))
        let open = AppcastItem(version: "500")
        #expect(prober.held(.updateAvailable(open)) == .updateAvailable(open))
    }

    /// The ring's newest build is held for this install: Sparkle offers nothing, so the ring has
    /// no way forward, and a Mac on a faster ring goes back to a kept build of this ring (or waits).
    /// A Mac that runs the held build is still on the ring.
    @Test func aHeldNewestBuildIsNoWayForwardOnTheRing() {
        let kept = KeptVersion(build: "300", shortVersion: "1.0.0", bundle: URL(fileURLWithPath: "/kept/300/cmux.app"),
                               storeSchemas: [:], teamID: "TEAM")
        let offered = [AppcastItem(version: "300", sparkleChannel: "cmux-next"),
                       AppcastItem(version: "600", sparkleChannel: "cmux-next", rolloutPercent: "0")]
        let rollout = StagedRollout(seed: 1)
        #expect(RingReturn.decide(installedBuild: "450", offered: offered, promoted: [], kept: [kept], rollout: rollout) == .goBack(kept))
        #expect(RingReturn.decide(installedBuild: "450", offered: offered, promoted: [], kept: [kept]) == .none)
        #expect(RingReturn.decide(installedBuild: "600", offered: offered, promoted: [], kept: [kept], rollout: rollout) == .none)
    }

    /// Sparkle picks the newest item this macOS runs, then holds it. On macOS 15: 500 open, 600 held
    /// and macOS 99 only. Sparkle offers 500, so the ring has a way forward; a held 600 is not one.
    @Test func theRingsWayForwardIsTheItemSparklePicksOnThisMacOS() throws {
        let kept = KeptVersion(build: "300", shortVersion: "1.0.0", bundle: URL(fileURLWithPath: "/kept/300/cmux.app"),
                               storeSchemas: [:], teamID: "TEAM")
        let macOS15 = SystemVersion(major: 15), future = try #require(SystemVersion("99.0"))
        let rollout = StagedRollout(seed: 1)
        let openThenHeldFuture = [AppcastItem(version: "300"), AppcastItem(version: "500"),
                                  AppcastItem(version: "600", minimumSystemVersion: future, rolloutPercent: "0")]
        #expect(RingReturn.decide(installedBuild: "450", offered: openThenHeldFuture, promoted: [], kept: [kept],
                                  rollout: rollout, system: macOS15) == .none)
        // 600 open but macOS 99 only, 500 held: Sparkle offers nothing here, so the way back shows.
        let heldThenOpenFuture = [AppcastItem(version: "300"), AppcastItem(version: "500", rolloutPercent: "0"),
                                  AppcastItem(version: "600", minimumSystemVersion: future)]
        #expect(RingReturn.decide(installedBuild: "450", offered: heldThenOpenFuture, promoted: [], kept: [kept],
                                  rollout: rollout, system: macOS15) == .goBack(kept))
    }

    /// A kept build the ring holds (halted at 0 %, not pulled) is not a way back.
    @Test func aHeldBuildIsNoWayBack() {
        let halted = KeptVersion(build: "600", shortVersion: "1.0.0", bundle: URL(fileURLWithPath: "/kept/600/cmux.app"),
                                 storeSchemas: [:], teamID: "TEAM")
        let offered = [AppcastItem(version: "600", rolloutPercent: "0")]
        #expect(RingReturn.decide(installedBuild: "700", offered: offered, promoted: [], kept: [halted],
                                  rollout: StagedRollout(seed: 1)) == .waits)
    }

    /// The note "needs a newer macOS" names the newest build this install's stage reaches.
    @Test func theNewerMacOSNoteNamesABuildTheStageReaches() throws {
        let future = try #require(SystemVersion("99.0"))
        var prober = UpdateProber(fetcher: Feed(xml: ""), architecture: .arm64)
        prober.rollout = StagedRollout(seed: 1)
        let items = [AppcastItem(version: "500", minimumSystemVersion: future),
                     AppcastItem(version: "600", minimumSystemVersion: future, rolloutPercent: "0")]
        guard case .requiresNewerSystem(let item, _) = prober.outcome(items, currentBuild: "300", system: SystemVersion(major: 15)) else {
            Issue.record("the note for build 500 is gone"); return
        }
        #expect(item.version == "500")
    }

    struct Feed: AppcastFetching { let xml: String; func fetch(_ url: URL) async throws -> Data { Data(xml.utf8) } }

    @Test func aBuildAtEveryInstallStillReplacesTheWaitingUpdate() async throws {
        let h = UpdateStagedYieldsToNewerTests.make(ring: "dev", feed: Self.feed(percent: "100"))
        h.rig.advance(by: .seconds(UpdateStagedYieldsToNewerTests.interval))
        h.rig.fireAtNow()
        try await UpdateStagedYieldsToNewerTests().settle(h, fetches: 1)
        #expect(h.sparkle.cancels == 1)
        #expect(h.sparkle.backgroundChecks == 1)
    }

    @Test func theProbeOffersOnlyWhatThisInstallsStageReaches() async throws {
        let identity = UpdateBuildIdentity(bundleIdentifier: "com.cmuxterm.app.next.rollout-probe", shortVersion: "1.0.0", build: "300",
                                           minimumSystemVersion: nil,
                                           infoFeedURL: "https://files-next.cmux.com/nightly-next/next/appcast-arm64.xml", hasPublicKey: true)
        var outside = UpdateProber(fetcher: Feed(xml: Self.feed(percent: "1")), architecture: .arm64)
        var seed: UInt64 = 1
        while StagedRollout(seed: seed).offers(version: "500", rawPercent: "1") { seed += 1 }
        outside.rollout = StagedRollout(seed: seed)
        let held = try await outside.probe(identity, allowedChannels: ["cmux-next", "cmux-next-dev"])
        if case .updateAvailable = held.outcome { Issue.record("a build outside this install's stage is offered") }
        var inside = outside
        seed = 1
        while !StagedRollout(seed: seed).offers(version: "500", rawPercent: "1") { seed += 1 }
        inside.rollout = StagedRollout(seed: seed)
        let offered = try await inside.probe(identity, allowedChannels: ["cmux-next", "cmux-next-dev"])
        guard case .updateAvailable(let item) = offered.outcome else { Issue.record("the stage's own install is not offered the build"); return }
        #expect(item.version == "500")
    }
}
