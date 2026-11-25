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

    @Test func theFirstFrameBeforeTheDropIsRecordedWaitsTheWholeBound() {
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(ConnectionChip.alreadyDownFor(ConnectionChip.justDropped, now: now) == .zero)
        #expect(ConnectionChip.alreadyDownFor(ConnectionChip.justDropped, now: now.addingTimeInterval(30)) == .zero,
                "the same instant on every render, so the wait is not restarted")
    }

    /// Leo, 2026-11-24: "let's just keep optimistically connecting": a link still coming up never
    /// draws a chip, however long it lasts; only a state the person can act on does.
    @Test func stillTryingKindsNeverShow() {
        #expect(ConnectionChip.Kind.allCases.filter(\.isStillTrying) == [.connecting, .reconnecting])
        #expect(ConnectionChip.Kind.allCases.filter { !$0.isStillTrying } .allSatisfy { $0.symbol != nil })
    }
}

#endif
