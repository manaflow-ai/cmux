@testable import CmuxNextUpdater
import Foundation
import Testing

/// Leo 2026-11-08: "it's just you click the button and that just simply restarts the app really
/// quickly". The install click used to read the feed and the pulled list after the click, before
/// the relaunch (up to the 3 s deadline, or the pulled list's 15 s). Now they are read ahead, as
/// the Update Ready card appears and when cmux becomes active, and a click within
/// ``StagedUpdateRefresh/clickReadFreshness`` of a whole read decides at once. An older read is
/// read again at the click, as before.
@MainActor @Suite(.serialized) struct UpdateClickReadAheadTests {
    typealias Base = UpdateStagedYieldsToNewerTests

    func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The harness with build 300 staged and nothing newer on the feed; installs counted.
    static func make() -> (Base.Harness, () -> Int) {
        let (h, installs) = UpdateClickInstallsNewestTests.make(newer: false)
        return (h, { installs.count })
    }

    @Test func theReadyCardReadsAheadAndTheClickInstallsWithNoNewRead() async throws {
        let (h, installs) = Self.make()
        // The card appeared (the harness stages 300): the feed and the pulled list are read ahead.
        #expect(await eventually { h.feed.fetches == 1 && h.updater.pulledWatch.lastReadAt != nil }, "nothing read ahead of the click")
        #expect(await eventually { h.updater.lastProbeAnsweredAt != nil })
        #expect(h.updater.stagedRefresh.hasFreshRead(h.updater))
        h.updater.installClicked()
        #expect(await eventually { installs() == 1 }, "the click did not install the staged build")
        #expect(h.feed.fetches == 1, "the click read the feed again: \(h.feed.fetches) reads")
        #expect(h.sparkle.cancels == 0)
    }

    @Test func aStaleReadIsReadAgainAtTheClick() async throws {
        let (h, installs) = Self.make()
        #expect(await eventually { h.updater.lastProbeAnsweredAt != nil && h.updater.pulledWatch.lastReadAt != nil })
        let fetched = h.feed.fetches
        h.updater.lastProbeAnsweredAt = h.updater.now().addingTimeInterval(-(StagedUpdateRefresh.clickReadFreshness + 1))
        #expect(!h.updater.stagedRefresh.hasFreshRead(h.updater))
        h.updater.installClicked()
        #expect(await eventually { installs() == 1 }, "the click did not install the staged build")
        #expect(h.feed.fetches == fetched + 1, "a read older than \(StagedUpdateRefresh.clickReadFreshness) s was trusted at the click")
    }

    /// Activation reads ahead too, once; a fresh read is not read again.
    @Test func activationReadsAheadOnlyWhenTheReadIsStale() async throws {
        let (h, _) = Self.make()
        #expect(await eventually { h.updater.lastProbeAnsweredAt != nil && h.updater.pulledWatch.lastReadAt != nil })
        let fetched = h.feed.fetches
        h.updater.prefetchForInstallClick()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.feed.fetches == fetched, "a fresh read was read again on activation")
        h.updater.lastProbeAnsweredAt = h.updater.now().addingTimeInterval(-(StagedUpdateRefresh.clickReadFreshness + 1))
        h.updater.prefetchForInstallClick()
        #expect(await eventually { h.feed.fetches == fetched + 1 }, "activation did not read a stale feed ahead")
    }
}
