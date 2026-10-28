import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// A key a cmux path holds and runs again keeps one latency slot, and a key dispatched inside another key's dispatch
/// does not take the outer key's echo stages away (first-keys-proof.md item 4; review of 107f5da1ac6).
@MainActor
struct InputLatencyHeldKeyTests {
    @Test func aNestedKeysEndGivesTheOuterKeyBackItsDispatchingSlot() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let now = harness.now
        let outer = try #require(harness.tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                       eventTimestamp: TimeInterval(now - 1_000_000) / 1e9, window: nil))
        // A held key run again inside the outer key's dispatch (CreationInputCoordinator.deliverEarly).
        let inner = try #require(harness.tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                       eventTimestamp: TimeInterval(now - 500_000_000) / 1e9, window: nil))
        #expect(harness.tracker.dispatchingKey == inner)
        harness.tracker.endDispatch(inner)
        #expect(harness.tracker.dispatchingKey == outer, "the outer key reached its terminal with no slot to arm its echo on")
        harness.tracker.endDispatch(outer)
        #expect(harness.tracker.dispatchingKey == nil)
    }

    @Test func aDiscardedFirstPassLeavesOneSlotForTheKey() throws {
        let harness = InputLatencyTrackerTests.Harness()
        let now = harness.now
        let first = try #require(harness.tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                       eventTimestamp: TimeInterval(now - 1_000_000) / 1e9, window: nil))
        harness.tracker.discard(first) // a creation hold took it
        harness.tracker.endDispatch(first)
        harness.advance(600_000_000)
        let replay = try #require(harness.tracker.begin(kind: .keyPress, target: .terminal, entrypoint: .person,
                                                        eventTimestamp: TimeInterval(now - 1_000_000) / 1e9, window: nil,
                                                        arrivedMain: now))
        harness.tracker.endDispatch(replay)
        harness.settle()
        #expect(harness.emitted.count == 1, "a held key counted as two keys")
        let slot = try #require(harness.emitted.first)
        #expect(slot.arrivedMain == now)
        #expect(slot.dispatchStart - slot.arrivedMain == 600_000_000, "the hold is not its own stage")
    }
}
