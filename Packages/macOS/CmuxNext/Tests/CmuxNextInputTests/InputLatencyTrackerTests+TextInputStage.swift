import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// TextInputStage (p04-input-101): a key's input method call is stamped between its dispatch start and end, once
/// when calls nest, only for the key down in dispatch, and ``InputLatencyDispatch`` hands it each key press's slot.
extension InputLatencyTrackerTests {
    /// A fake input context: the input method round trip, which takes `nanos` on the harness clock and may re-send a
    /// chord (a nested call).
    @MainActor
    final class FakeInputContext {
        let harness: Harness
        let stage: TextInputStage
        private(set) var handled = 0

        init(harness: Harness, stage: TextInputStage) {
            self.harness = harness
            self.stage = stage
        }

        func handle(taking nanos: UInt64, resending: Bool = false) {
            stage.interpreting {
                handled += 1
                harness.advance(nanos)
                if resending { handle(taking: nanos) }
            }
        }
    }

    private func beginKey(_ harness: Harness, kind: InputEventKind = .keyPress) throws -> InputLatencyToken {
        try #require(harness.tracker.begin(kind: kind, target: .textView, entrypoint: .person,
                                           eventTimestamp: TimeInterval(harness.now - 1_000_000) / 1e9, window: nil))
    }

    @Test("The input method call is stamped between the key's dispatch start and end")
    func textInputStageOrder() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let token = try beginKey(harness)
        let outer = stage.keyDownDispatchBegan(token)
        harness.advance(100_000)
        context.handle(taking: 400_000)
        harness.advance(200_000)
        harness.tracker.endDispatch(token)
        stage.keyDownDispatchEnded(restoring: outer)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        let order: [InputStage] = [.dispatchStart, .textInputStart, .textInputEnd, .dispatchEnd]
        for stage in order { #expect(slot.reached(stage), "\(stage)") }
        for (earlier, later) in zip(order, order.dropFirst()) {
            #expect(slot[earlier] <= slot[later], "\(earlier) before \(later)")
        }
        #expect(slot.nanos(from: .dispatchStart, to: .textInputStart) == 100_000)
        #expect(slot.nanos(from: .textInputStart, to: .textInputEnd) == 400_000)
        #expect(slot.nanos(from: .textInputEnd, to: .dispatchEnd) == 200_000)
        #expect(context.handled == 1)
        #expect(stage.keyDown == nil, "the dispatch returned")
    }

    @Test("A call inside another (a re-sent chord) runs, and the outer call's stamps cover both")
    func nestedTextInputStampsOnce() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let token = try beginKey(harness)
        let outer = stage.keyDownDispatchBegan(token)
        context.handle(taking: 300_000, resending: true)
        harness.tracker.endDispatch(token)
        stage.keyDownDispatchEnded(restoring: outer)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(context.handled == 2, "both calls ran")
        #expect(slot.nanos(from: .textInputStart, to: .textInputEnd) == 600_000, "one span over both")
    }

    @Test("With no key down in dispatch the call runs and stamps nothing")
    func textInputWithoutKeyStampsNothing() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let click = try beginKey(harness, kind: .mousePress)
        context.handle(taking: 300_000)
        harness.tracker.endDispatch(click)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(context.handled == 1)
        #expect(!slot.reached(.textInputStart) && !slot.reached(.textInputEnd))
    }

    @Test("A key dispatched inside another's stamps its own slot, then the outer key's slot gets its call")
    func nestedKeyDispatchRestoresOuterKey() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let first = try beginKey(harness)
        let none = stage.keyDownDispatchBegan(first)
        harness.advance(50_000)
        let second = try beginKey(harness)
        let outer = stage.keyDownDispatchBegan(second)
        #expect(outer == first)
        context.handle(taking: 100_000)
        harness.tracker.endDispatch(second)
        stage.keyDownDispatchEnded(restoring: outer)
        #expect(stage.keyDown == first)
        context.handle(taking: 200_000)
        harness.tracker.endDispatch(first)
        stage.keyDownDispatchEnded(restoring: none)
        harness.commit()

        // Slots close in the order they opened: the outer key's first.
        #expect(harness.emitted.count == 2)
        let outerSlot = try #require(harness.emitted.first)
        let innerSlot = try #require(harness.emitted.last)
        #expect(outerSlot.dispatchStart < innerSlot.dispatchStart)
        #expect(outerSlot.nanos(from: .textInputStart, to: .textInputEnd) == 200_000, "the outer key's own call")
        #expect(innerSlot.nanos(from: .textInputStart, to: .textInputEnd) == 100_000, "the inner key's own call")
        #expect(stage.keyDown == nil)
    }

    @Test("The dispatch hands the stage each key press's slot for its dispatch only, and no other event's")
    func dispatchHandsKeySlotToStage() throws {
        let harness = Harness()
        let dispatch = InputLatencyDispatch(tracker: harness.tracker, classifier: InputTargetClassifier(rules: []),
                                            frameInterval: { _ in 0.01 }, windowChanged: { _ in false })
        let key = try #require(dispatch.open(.keyDown, scrollPhase: .none, timestamp: 0.5, window: nil,
                                             synthetic: false, keyWindow: nil, underPointer: { .other }))
        #expect(dispatch.textInput.keyDown == key.token)
        dispatch.textInput.interpreting { harness.advance(250_000) }
        dispatch.didDispatch(key, layoutTookScroll: false)
        #expect(dispatch.textInput.keyDown == nil)

        let click = try #require(dispatch.open(.leftMouseDown, scrollPhase: .none, timestamp: 0.5, window: nil,
                                               synthetic: false, keyWindow: nil, underPointer: { .other }))
        #expect(dispatch.textInput.keyDown == nil, "a click has no text input call")
        dispatch.didDispatch(click, layoutTookScroll: false)
        harness.commit()

        let keySlot = try #require(harness.emitted.first { $0.kind == .keyPress })
        #expect(keySlot.nanos(from: .textInputStart, to: .textInputEnd) == 250_000)
        #expect(keySlot[.textInputEnd] <= keySlot[.dispatchEnd])
    }
}
