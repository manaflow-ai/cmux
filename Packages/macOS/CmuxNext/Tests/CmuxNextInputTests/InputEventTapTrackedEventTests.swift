import AppKit
import CmuxNextInput
import Testing

/// Event identity outside a handler's own event (DC7): AppKit's current event counts
/// only when a tracking loop took it after the last dispatched event (a menu item's mouse-up, a
/// control's release); the dispatched event itself, or an older one, reads nil, as a socket or CLI
/// run after a click must.
@MainActor @Suite(.serialized)
struct InputEventTapTrackedEventTests {
    @Test func beforeAnyDispatchTheCurrentEventCounts() throws {
        let tap = InputEventTap()
        let up = try Self.mouse(.leftMouseUp, at: 2)
        #expect(tap.trackedEvent(current: up) === up)
        #expect(tap.trackedEvent(current: nil) == nil)
    }

    @Test func aTrackingLoopsReleaseCountsAndTheDispatchedPressDoesNot() throws {
        let tap = InputEventTap()
        let down = try Self.mouse(.leftMouseDown, at: 1)
        Self.dispatch(down, through: tap)
        let up = try Self.mouse(.leftMouseUp, at: 2, modifiers: .command)
        #expect(tap.trackedEvent(current: up) === up, "the release the menu's loop took was dropped")
        #expect(tap.trackedEvent(current: up)?.modifierFlags.contains(.command) == true)
        #expect(tap.trackedEvent(current: down) == nil, "the dispatched press read as a tracked event")
    }

    @Test func aSocketRunAfterAClickReadsNothing() throws {
        let tap = InputEventTap()
        let click = try Self.mouse(.leftMouseDown, at: 5, modifiers: .option)
        Self.dispatch(click, through: tap)
        // Between dispatches AppKit still reports the click as its current event.
        #expect(tap.trackedEvent(current: click) == nil, "a run after the click read the click's Option")
        #expect(tap.trackedEvent(current: try Self.mouse(.leftMouseUp, at: 4)) == nil, "an older event counted")
    }

    @Test func theLastDispatchedEventIsMatchedByTimeAndType() throws {
        let tap = InputEventTap()
        let down = try Self.mouse(.rightMouseDown, at: 3)
        #expect(!tap.isLastDispatched(down), "nothing was dispatched yet")
        Self.dispatch(down, through: tap)
        #expect(tap.isLastDispatched(down))
        #expect(!tap.isLastDispatched(try Self.mouse(.rightMouseUp, at: 3)), "another type matched")
        Self.dispatch(try Self.mouse(.mouseMoved, at: 4), through: tap)
        #expect(!tap.isLastDispatched(down), "a later move left the press current")
    }

    private static func dispatch(_ event: NSEvent, through tap: InputEventTap) {
        tap.dispatching {
            tap.deliverObserve(event)
            _ = tap.deliverIntercepts(event)
            tap.deliverAfterDispatch(event)
        }
    }

    private static func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval,
                              modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
