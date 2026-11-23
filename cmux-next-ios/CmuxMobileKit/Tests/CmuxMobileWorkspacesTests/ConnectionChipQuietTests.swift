#if os(iOS)
@testable import CmuxMobileDesign
import Foundation
import Testing

/// A connection chip says nothing until its link has been down for the shared bound, counted
/// from when the link dropped, not from when the chip appeared (cmuxterm-hq
/// docs/handbook/connection-state-with-no-action-or-bound.md). On a clock that moves only
/// when told, so no wall time is read.
@MainActor @Suite struct ConnectionChipQuietTests {
    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    @Test func theBoundIsTheSchemas() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appending(path: "schemas/notice-timing/notice-timing.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ms = try #require(json["connectionQuietMs"] as? Int)
        #expect(QuietStatusGate.threshold == .milliseconds(ms))
    }

    @Test func aFreshDropWaitsTheWholeBound() async {
        let clock = RecordedClock()
        let gate = QuietStatusGate(clock: clock)
        gate.update(down: true, alreadyDownFor: .zero)
        #expect(!gate.isShown, "nothing at the drop")
        await settle()
        #expect(clock.sleptUntil == [RecordedClock.at(QuietStatusGate.threshold)])
        #expect(gate.isShown, "shown once the bound has passed")
    }

    @Test func aChipThatAppearsMidOutageWaitsOnlyWhatIsLeft() async {
        let clock = RecordedClock()
        let gate = QuietStatusGate(clock: clock)
        gate.update(down: true, alreadyDownFor: .seconds(4))
        #expect(!gate.isShown)
        await settle()
        #expect(clock.sleptUntil == [RecordedClock.at(QuietStatusGate.threshold - .seconds(4))],
                "a re-render or a sheet over it does not restart the wait")
        #expect(gate.isShown)
    }

    @Test func anOutagePastTheBoundShowsAtOnce() {
        let clock = RecordedClock()
        let gate = QuietStatusGate(clock: clock)
        gate.update(down: true, alreadyDownFor: .seconds(12))
        #expect(gate.isShown)
        #expect(clock.sleptUntil.isEmpty)
    }

    @Test func aLinkBackBeforeTheBoundShowsNothing() async {
        let gate = QuietStatusGate(clock: ContinuousClock())
        gate.update(down: true, alreadyDownFor: .seconds(3))
        gate.update(down: false)
        await settle()
        #expect(!gate.isShown)
    }

    @Test func theDownTimeIsKeptWhileDownAndClearedWhenBack() {
        let drop = Date(timeIntervalSince1970: 1_000)
        let first = ConnectionChip.nextDownSince(nil, down: true, now: drop)
        #expect(first == drop)
        // Reconnecting to Mac offline, still down: the same instant.
        #expect(ConnectionChip.nextDownSince(first, down: true, now: drop.addingTimeInterval(6)) == drop)
        #expect(ConnectionChip.nextDownSince(first, down: false, now: drop.addingTimeInterval(7)) == nil)
        #expect(ConnectionChip.alreadyDownFor(drop, now: drop.addingTimeInterval(3)) == .seconds(3))
        #expect(ConnectionChip.alreadyDownFor(nil, now: drop) == QuietStatusGate.threshold,
                "a caller that held it shows at once")
    }

    /// The review of cmux#51275: a chip that appears only after a hold upstream (the
    /// coordinator holds Reconnecting for the bound, a stream closes some time after its link)
    /// counted its own 10 s from when it appeared, so Reconnecting showed at about 20 s. It
    /// counts from the link's drop now: the earliest record wins.
    @Test func aChipAfterAHoldCountsFromTheLinkDrop() {
        let drop = Date(timeIntervalSince1970: 1_000)
        let appeared = drop.addingTimeInterval(10)
        #expect(ConnectionChip.earliest(drop, appeared) == drop)
        #expect(ConnectionChip.earliest(nil, appeared) == appeared, "no link record: the chip's own")
        #expect(ConnectionChip.earliest(nil, nil) == ConnectionChip.justDropped)
    }

    @Test func aChipHeldForTheBoundUpstreamShowsAtOnce() {
        let clock = RecordedClock()
        let drop = Date(timeIntervalSince1970: 1_000)
        let appeared = drop.addingTimeInterval(10)
        let gate = QuietStatusGate(clock: clock)
        gate.update(down: true, alreadyDownFor: ConnectionChip.alreadyDownFor(
            ConnectionChip.earliest(drop, appeared), now: appeared))
        #expect(gate.isShown, "zero extra wait after the coordinator's 10 s hold")
        #expect(clock.sleptUntil.isEmpty)
    }

    @Test func aChipThatAppearsFourSecondsIntoTheDropWaitsSix() async {
        let clock = RecordedClock()
        let drop = Date(timeIntervalSince1970: 1_000)
        let appeared = drop.addingTimeInterval(4)
        let gate = QuietStatusGate(clock: clock)
        gate.update(down: true, alreadyDownFor: ConnectionChip.alreadyDownFor(
            ConnectionChip.earliest(drop, appeared), now: appeared))
        #expect(!gate.isShown)
        await settle()
        #expect(clock.sleptUntil == [RecordedClock.at(.seconds(6))], "10 s from the drop, not from the chip")
        #expect(gate.isShown)
    }

    @Test func theFirstFrameBeforeTheDropIsRecordedWaitsTheWholeBound() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ConnectionChip.alreadyDownFor(ConnectionChip.justDropped, now: now) == .zero)
        #expect(ConnectionChip.alreadyDownFor(ConnectionChip.justDropped, now: now.addingTimeInterval(30)) == .zero,
                "the same instant on every render, so the wait is not restarted")
    }
}
#endif
