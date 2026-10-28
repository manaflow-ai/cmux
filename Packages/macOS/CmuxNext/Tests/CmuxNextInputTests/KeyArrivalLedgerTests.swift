import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// A key-down's first arrival on the main thread survives a cmux path's hold and second `sendEvent`
/// (first-seconds-evidence.md step 1): the slot's `arrivedMain` is that first arrival, so the hold shows as
/// `arrivedMain -> dispatchStart`, not as the main thread's wait.
@MainActor
struct KeyArrivalLedgerTests {
    static func key(_ code: UInt16, at seconds: TimeInterval) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: seconds, windowNumber: 0,
                         context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: code)!
    }

    @Test func aHeldKeySentAgainKeepsItsFirstArrival() {
        let ledger = KeyArrivalLedger()
        let event = Self.key(0, at: 10)
        #expect(ledger.arrived(event, at: 10_001_000_000) == 10_001_000_000)
        ledger.held(event, by: .creation, at: 10_001_100_000)
        // Sent again 900 ms later through sendEvent: the first arrival comes back.
        #expect(ledger.arrived(event, at: 10_900_000_000) == 10_001_000_000)
        let history = ledger.history(of: event)
        #expect(history.heldBy == .creation)
        #expect(history.deliveries == 2)
    }

    @Test func anotherKeyIsItsOwnArrival() {
        let ledger = KeyArrivalLedger()
        _ = ledger.arrived(Self.key(0, at: 10), at: 10_001_000_000)
        #expect(ledger.arrived(Self.key(1, at: 10), at: 10_002_000_000) == 10_002_000_000)
        #expect(ledger.arrived(Self.key(0, at: 11), at: 11_001_000_000) == 11_001_000_000)
    }

    @Test func aKeyHeldBeforeSendEventCountsItsHoldFromTheHold() {
        let ledger = KeyArrivalLedger()
        let event = Self.key(0, at: 10)
        ledger.held(event, by: .newTab, at: 10_002_000_000)
        #expect(ledger.arrived(event, at: 10_500_000_000) == 10_002_000_000)
        #expect(ledger.history(of: event) == (.newTab, 1))
    }

    @Test func aLateReplayIsLoggedAsHeldNotAsAMainThreadWait() throws {
        let ledger = KeyArrivalLedger()
        let event = Self.key(0, at: 10)
        _ = ledger.arrived(event, at: 10_002_000_000)
        ledger.held(event, by: .creation, at: 10_002_000_000)
        let first = ledger.arrived(event, at: 10_800_000_000)
        ledger.logIfLate(event, arrived: first, dispatchStart: 10_800_000_000, target: .terminal, keyWindow: nil)
        let late = try #require(ledger.lateKeys().last)
        #expect(late.heldBy == .creation)
        #expect(late.arrivedMainNanos - late.generatedNanos == 2_000_000)
        #expect(late.dispatchStartNanos - late.arrivedMainNanos == 798_000_000)
        // A key dispatched 50 ms after its OS time is not late.
        let quick = Self.key(1, at: 20)
        ledger.logIfLate(quick, arrived: 20_050_000_000, dispatchStart: 20_050_000_000, target: nil, keyWindow: nil)
        #expect(ledger.lateTotal == 1)
    }

    @Test func lateKeysKeepTheNewest() {
        let ledger = KeyArrivalLedger()
        for index in 0..<(KeyArrivalLedger.lateCapacity + 3) {
            ledger.logLate(.init(keyCode: UInt16(index % 100), generatedNanos: UInt64(index), arrivedMainNanos: UInt64(index),
                                 dispatchStartNanos: UInt64(index) + KeyArrivalLedger.lateNanos + 1, deliveries: 1,
                                 heldBy: .none, target: nil, responderChain: [], responderAgeNanos: nil))
        }
        #expect(ledger.lateTotal == UInt64(KeyArrivalLedger.lateCapacity + 3))
        #expect(ledger.lateKeys().count == KeyArrivalLedger.lateCapacity)
        #expect(ledger.lateKeys(1).first?.generatedNanos == UInt64(KeyArrivalLedger.lateCapacity + 2))
    }
}
