import Testing
@testable import CmuxSettings

@Suite("Shortcut prefix pass-through ledger")
struct ShortcutPrefixChordPassThroughLedgerTests {
    @Test func distinctSyntheticIdentitiesAtOneTimestampRemainIndependent() {
        var ledger = ShortcutPrefixChordPassThroughLedger(capacity: 4)
        let first = ShortcutPrefixChordEventIdentity(
            windowID: 1,
            keyCode: 12,
            modifierFlags: 0,
            timestamp: 42
        )
        let second = ShortcutPrefixChordEventIdentity(
            windowID: 1,
            keyCode: 13,
            modifierFlags: 0,
            timestamp: 42
        )

        ledger.mark(first)
        ledger.mark(second)

        #expect(ledger.count == 2)
        #expect(ledger.contains(first))
        #expect(ledger.contains(second))
        let consumedFirst = ledger.consume(first)
        let consumedFirstAgain = ledger.consume(first)
        let consumedSecond = ledger.consume(second)
        #expect(consumedFirst)
        #expect(!consumedFirstAgain)
        #expect(consumedSecond)
        #expect(ledger.count == 0)
    }

    @Test func copiedIdentityIsConsumedExactlyOnce() {
        var ledger = ShortcutPrefixChordPassThroughLedger()
        let original = ShortcutPrefixChordEventIdentity(
            eventNumber: 99,
            windowID: 3,
            keyCode: 45,
            modifierFlags: 1,
            timestamp: 1.5
        )
        let replay = ShortcutPrefixChordEventIdentity(
            eventNumber: 99,
            windowID: 8,
            keyCode: 1,
            modifierFlags: 0,
            timestamp: 9
        )

        ledger.mark(original)

        let consumedReplay = ledger.consume(replay)
        let consumedReplayAgain = ledger.consume(replay)
        #expect(consumedReplay)
        #expect(!consumedReplayAgain)
        #expect(ledger.count == 0)
    }

    @Test func fifoCapacityDropsOnlyTheOldestMarker() {
        var ledger = ShortcutPrefixChordPassThroughLedger(capacity: 2)
        let identities = (0..<3).map { index in
            ShortcutPrefixChordEventIdentity(
                eventNumber: UInt64(index + 1),
                keyCode: UInt16(index),
                modifierFlags: 0,
                timestamp: Double(index)
            )
        }

        for identity in identities {
            ledger.mark(identity)
        }

        #expect(ledger.count == 2)
        #expect(!ledger.contains(identities[0]))
        #expect(ledger.contains(identities[1]))
        #expect(ledger.contains(identities[2]))
    }

    @Test func remarkingOneIdentityDoesNotConsumeCapacity() {
        var ledger = ShortcutPrefixChordPassThroughLedger(capacity: 2)
        let first = ShortcutPrefixChordEventIdentity(
            eventNumber: 1,
            keyCode: 0,
            modifierFlags: 0,
            timestamp: 0
        )
        let second = ShortcutPrefixChordEventIdentity(
            eventNumber: 2,
            keyCode: 1,
            modifierFlags: 0,
            timestamp: 1
        )

        ledger.mark(first)
        ledger.mark(first)
        ledger.mark(second)

        #expect(ledger.count == 2)
        #expect(ledger.contains(first))
        #expect(ledger.contains(second))
    }
}
