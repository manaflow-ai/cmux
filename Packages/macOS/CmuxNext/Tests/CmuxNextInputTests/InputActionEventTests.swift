import AppKit
@testable import CmuxNextInput
import CmuxNextInputCore
import Testing

/// The event an action answers (p04-input-067): the event being dispatched, or a menu or control's
/// tracking event that no dispatch replaced (Option pressed while a menu is open), never an old event
/// AppKit keeps as its current one after its dispatch ended (a CLI or socket run reads nil).
@MainActor @Suite(.serialized)
struct InputActionEventTests {
    @Test func aMenuChoiceWithOptionPressedDuringTrackingReadsOption() throws {
        let tap = InputEventTap()
        let rightDown = try Self.mouse(.rightMouseDown, at: 10)
        let chosen = try Self.mouse(.leftMouseUp, at: 10.4, modifiers: [.option])
        tap.deliverObserve(rightDown)
        // The context menu tracks inside the right-click's dispatch; its loop dequeued the mouse-up itself.
        let event = InputEventTap.actionEvent(dispatched: rightDown, lastDispatched: tap.lastDispatched, tracking: chosen)
        #expect(event === chosen, "the menu's own choosing event is the action's event")
        #expect(event?.modifierFlags.contains(.option) == true, "Option held in the menu is read")
    }

    @Test func aMenuBarChoiceOutsideAnyDispatchReadsItsTrackingEvent() throws {
        let tap = InputEventTap()
        tap.deliverObserve(try Self.mouse(.leftMouseDown, at: 5))
        let chosen = try Self.mouse(.leftMouseUp, at: 6, modifiers: [.option])
        let event = InputEventTap.actionEvent(dispatched: nil, lastDispatched: tap.lastDispatched, tracking: chosen)
        #expect(event === chosen)
    }

    @Test func aRunBetweenDispatchesHasNoEventThoughAppKitKeepsTheLastOne() throws {
        let tap = InputEventTap()
        let key = try Self.key(at: 20)
        tap.deliverObserve(key)
        // AppKit's current event is still the key whose dispatch ended: a CLI or socket run reads nil.
        #expect(InputEventTap.actionEvent(dispatched: nil, lastDispatched: tap.lastDispatched, tracking: key) == nil)
        // A later move replaced it as the last dispatched event: still nil.
        tap.deliverObserve(try Self.mouse(.mouseMoved, at: 21))
        #expect(InputEventTap.actionEvent(dispatched: nil, lastDispatched: tap.lastDispatched, tracking: key) == nil)
    }

    @Test func theDispatchedEventWinsOverAnOlderTrackingEvent() throws {
        let tap = InputEventTap()
        let stale = try Self.key(at: 30)
        tap.deliverObserve(stale)
        // The key router's own key (`debug.key`, a held key replayed) is dispatched without AppKit dequeuing it.
        let routed = try Self.key(at: 31)
        #expect(InputEventTap.actionEvent(dispatched: routed, lastDispatched: tap.lastDispatched, tracking: stale) === routed)
        #expect(InputEventTap.actionEvent(dispatched: routed, lastDispatched: tap.lastDispatched, tracking: routed) === routed)
    }

    @Test func theTapReadsItsDispatchedEventSource() throws {
        let tap = InputEventTap()
        #expect(tap.dispatchedEvent() == nil, "an unwired tap dispatches nothing")
        let key = try Self.key(at: ProcessInfo.processInfo.systemUptime + 60)
        let dispatch = Dispatch(event: key)
        tap.dispatchedEvent = { dispatch.event }
        // AppKit's current event in this test process is older than the key: the dispatched key answers.
        #expect(tap.actionEvent === key)
        dispatch.event = nil
        tap.deliverObserve(key)
        #expect(tap.actionEvent !== key, "after its dispatch the key is not the action's event")
    }

    /// The event a fake dispatch holds: a class, so the `@MainActor` source shares it without capturing a local `var`.
    final class Dispatch {
        var event: NSEvent?
        init(event: NSEvent?) { self.event = event }
    }

    private static func key(at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: "a",
                                             charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    private static func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval,
                              modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
