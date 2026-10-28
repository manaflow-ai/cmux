import AppKit
@testable import CmuxNextInput
import Testing

/// The one seam that sends a held key again (hold-class.md item c): every replay records its path's hold (held_by and
/// hold ms) before the key goes on, so a hold is a measured stage in `debug.input`, never an unseen wait.
@MainActor
struct HeldKeyReplayTests {
    private final class Clock {
        var nanos: UInt64 = 0
    }

    private final class KeyView: NSView {
        var keys: [UInt16] = []
        override func keyDown(with event: NSEvent) { keys.append(event.keyCode) }
    }

    private static func key(_ code: UInt16, at seconds: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: seconds, windowNumber: 0,
                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!
    }

    @Test func aReplayRecordsItsHoldFromTheMomentThePathHeldTheKey() {
        let ledger = KeyArrivalLedger()
        let clock = Clock()
        let replay = HeldKeyReplay(ledger: ledger) { clock.nanos }
        let event = Self.key(0, at: 10)
        _ = ledger.arrived(event, at: 10_001_000_000)
        ledger.held(event, by: .newTab, at: 10_002_000_000)
        clock.nanos = 10_032_000_000
        var sent = false
        replay.replay(event, heldBy: .newTab, keyWindow: nil) { _ in sent = true }
        #expect(sent)
        let stage = replay.stage(.newTab)
        #expect(stage.count == 1)
        #expect(stage.maxNanos == 30_000_000)
        #expect(stage.overLimit == 0)
        #expect(stage.buckets[2] == 1)  // 30 ms: the 16-33 ms bucket
        #expect(replay.stage(.creation).count == 0)
    }

    @Test func aHoldPastTheLimitCountsAndALateKeyIsLoggedWithItsPath() throws {
        let ledger = KeyArrivalLedger()
        let clock = Clock()
        let replay = HeldKeyReplay(ledger: ledger) { clock.nanos }
        let event = Self.key(4, at: 20)
        _ = ledger.arrived(event, at: 20_001_000_000)
        ledger.held(event, by: .launchPicture, at: 20_001_000_000)
        clock.nanos = 22_001_000_000
        replay.replay(event, heldBy: .launchPicture, keyWindow: nil) { _ in }
        let stage = replay.stage(.launchPicture)
        #expect(stage.overLimit == 1)
        #expect(stage.maxNanos == 2_000_000_000)
        #expect(stage.buckets.last == 1)
        let late = try #require(ledger.lateKeys().last)
        #expect(late.heldBy == .launchPicture)
        #expect(replay.stages.map(\.path) == [.launchPicture])
    }

    @Test func withoutALedgerTheHoldCountsFromTheKeysOSTime() {
        let clock = Clock()
        let replay = HeldKeyReplay(ledger: nil) { clock.nanos }
        clock.nanos = 5_100_000_000
        replay.replay(Self.key(1, at: 5), heldBy: .creation, keyWindow: nil) { _ in }
        #expect(replay.stage(.creation).maxNanos == 100_000_000)
    }

    /// A key replayed, held again by the dispatch the replay ran (the launch picture: undecided, then for a terminal
    /// still a picture) and sent again later is ONE key with ONE hold: from its first hold to its last send.
    @Test func aKeyHeldAgainByItsOwnReplayCountsOnceWithItsWholeHold() {
        let ledger = KeyArrivalLedger()
        let clock = Clock()
        let replay = HeldKeyReplay(ledger: ledger) { clock.nanos }
        let event = Self.key(2, at: 30)
        _ = ledger.arrived(event, at: 30_001_000_000)
        ledger.held(event, by: .launchPicture, at: 30_001_000_000)
        clock.nanos = 30_021_000_000
        replay.replay(event, heldBy: .launchPicture, keyWindow: nil) { _ in }
        clock.nanos = 30_201_000_000
        replay.replay(event, heldBy: .launchPicture, keyWindow: nil) { _ in }
        let stage = replay.stage(.launchPicture)
        #expect(stage.count == 1, "one key counted \(stage.count) times")
        #expect(stage.maxNanos == 200_000_000)
        #expect(stage.totalNanos == 200_000_000)
        #expect(stage.overLimit == 1)
        #expect(stage.buckets.reduce(0, +) == 1)
        #expect(stage.buckets[5] == 1)  // 200 ms: the 100-250 ms bucket
    }

    /// The stage table is indexed by the path's raw value.
    @Test func holdPathRawValuesAreTheirIndexes() {
        #expect(KeyArrivalLedger.HoldPath.allCases.map { Int($0.rawValue) } == Array(0 ..< KeyArrivalLedger.HoldPath.allCases.count))
    }

    @Test func theSenderGivesTheKeyToTheViewNamed() {
        let replay = HeldKeyReplay(ledger: nil) { 0 }
        let view = KeyView()
        let event = Self.key(7, at: 0)
        replay.replay(event, heldBy: .launchPicture, keyWindow: nil) { send in send.view(view, event) }
        #expect(view.keys == [7])
        // A key with no OS time and no ledger entry counts a zero hold, never a wrapped one.
        #expect(replay.stage(.launchPicture).maxNanos == 0)
        #expect(replay.stage(.launchPicture).count == 1)
    }
}
