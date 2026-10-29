import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// TextInputStage: a key's input method call is stamped between its dispatch start and end, once
/// when calls nest, only for the key down in dispatch (never for another key interpreted during its dispatch), and
/// ``InputLatencyDispatch`` hands it each key press's slot.
extension InputLatencyTrackerTests {
    /// A fake input context: the input method round trip for `event`, which takes `nanos` on the harness clock and
    /// may re-send a chord (a nested call).
    @MainActor
    final class FakeInputContext {
        let harness: Harness
        let stage: TextInputStage
        private(set) var handled = 0

        init(harness: Harness, stage: TextInputStage) {
            self.harness = harness
            self.stage = stage
        }

        func handle(_ event: NSEvent, taking nanos: UInt64, resending: Bool = false) {
            stage.interpreting(event) {
                handled += 1
                harness.advance(nanos)
                if resending { handle(event, taking: nanos) }
            }
        }
    }

    /// A key down event typed `ageNanos` before the harness clock's now.
    static func keyEvent(_ harness: Harness, ageNanos: UInt64 = 1_000_000) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                      timestamp: TimeInterval(harness.now - ageNanos) / 1e9, windowNumber: 0,
                                      context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                      isARepeat: false, keyCode: 0))
    }

    /// Opens a key slot for `event` (or a click's slot for `kind: .mousePress`).
    private func beginKey(_ harness: Harness, _ event: NSEvent,
                       kind: InputEventKind = .keyPress) throws -> InputLatencyToken {
        try #require(harness.tracker.begin(kind: kind, target: .textView, entrypoint: .person,
                                           eventTimestamp: event.timestamp, window: nil))
    }

    @Test("The input method call is stamped between the key's dispatch start and end")
    func textInputStageOrder() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let event = try Self.keyEvent(harness)
        let token = try beginKey(harness, event)
        let outer = stage.keyDownDispatchBegan(token, timestamp: event.timestamp)
        harness.advance(100_000)
        context.handle(event, taking: 400_000)
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
        let event = try Self.keyEvent(harness)
        let token = try beginKey(harness, event)
        let outer = stage.keyDownDispatchBegan(token, timestamp: event.timestamp)
        context.handle(event, taking: 300_000, resending: true)
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
        let event = try Self.keyEvent(harness)
        let click = try beginKey(harness, event, kind: .mousePress)
        context.handle(event, taking: 300_000)
        harness.tracker.endDispatch(click)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(context.handled == 1)
        #expect(!slot.reached(.textInputStart) && !slot.reached(.textInputEnd))
    }

    /// The launch picture's held keys: key N's dispatch delivers keys 1..N-1, typed earlier, to the terminal around
    /// `sendEvent` (`KeyRouter.deliverKeys`). Their input method calls must not take key N's stamps, which a slot
    /// writes once.
    @Test("Another key interpreted during a key's dispatch stamps nothing; the key's own call still stamps its slot")
    func otherKeyDuringDispatchStampsNothing() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let held = try Self.keyEvent(harness, ageNanos: 40_000_000)
        let event = try Self.keyEvent(harness)
        let token = try beginKey(harness, event)
        let outer = stage.keyDownDispatchBegan(token, timestamp: event.timestamp)
        context.handle(held, taking: 500_000)
        harness.advance(100_000)
        context.handle(event, taking: 300_000)
        harness.tracker.endDispatch(token)
        stage.keyDownDispatchEnded(restoring: outer)
        harness.commit()

        let slot = try #require(harness.emitted.first)
        #expect(context.handled == 2, "the held key's call still ran")
        #expect(slot.nanos(from: .textInputStart, to: .textInputEnd) == 300_000, "the key's own call, not the held key's")
        #expect(slot.nanos(from: .dispatchStart, to: .textInputStart) == 600_000)
    }

    @Test("A key dispatched inside another's stamps its own slot, then the outer key's slot gets its call")
    func nestedKeyDispatchRestoresOuterKey() throws {
        let harness = Harness()
        let stage = TextInputStage(tracker: harness.tracker)
        let context = FakeInputContext(harness: harness, stage: stage)
        let firstEvent = try Self.keyEvent(harness)
        let first = try beginKey(harness, firstEvent)
        let none = stage.keyDownDispatchBegan(first, timestamp: firstEvent.timestamp)
        harness.advance(50_000)
        let secondEvent = try Self.keyEvent(harness, ageNanos: 10_000)
        let second = try beginKey(harness, secondEvent)
        let outer = stage.keyDownDispatchBegan(second, timestamp: secondEvent.timestamp)
        #expect(outer?.token == first)
        context.handle(secondEvent, taking: 100_000)
        harness.tracker.endDispatch(second)
        stage.keyDownDispatchEnded(restoring: outer)
        #expect(stage.keyDown?.token == first)
        context.handle(firstEvent, taking: 200_000)
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
        let event = try Self.keyEvent(harness)
        let key = try #require(dispatch.open(.keyDown, scrollPhase: .none, timestamp: event.timestamp, window: nil,
                                             synthetic: false, keyWindow: nil, underPointer: { .other }))
        #expect(dispatch.textInput.keyDown == TextInputStage.KeyDown(token: key.token, timestamp: event.timestamp))
        dispatch.textInput.interpreting(event) { harness.advance(250_000) }
        dispatch.didDispatch(key, layoutTookScroll: false)
        #expect(dispatch.textInput.keyDown == nil)

        let click = try #require(dispatch.open(.leftMouseDown, scrollPhase: .none, timestamp: event.timestamp,
                                               window: nil, synthetic: false, keyWindow: nil,
                                               underPointer: { .other }))
        #expect(dispatch.textInput.keyDown == nil, "a click has no text input call")
        dispatch.didDispatch(click, layoutTookScroll: false)
        harness.commit()

        let keySlot = try #require(harness.emitted.first { $0.kind == .keyPress })
        #expect(keySlot.nanos(from: .textInputStart, to: .textInputEnd) == 250_000)
        #expect(keySlot[.textInputEnd] <= keySlot[.dispatchEnd])
    }
}
