import AppKit
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextInput
import Testing

/// The focus source of a user-invoked change comes from the event the action answers (p04-input-067), never
/// from AppKit's current event after its dispatch ended (cx-3hw0i.2).
@MainActor @Suite(.serialized)
struct FocusCoordinatorTests {
    @Test func theSourceIsTheDeviceOfTheActionsEvent() throws {
        #expect(FocusEvent.Source.of(try Self.key(at: 1)) == .keyboard)
        #expect(FocusEvent.Source.of(try Self.mouse(.leftMouseDown, at: 1)) == .mouse)
        #expect(FocusEvent.Source.of(try Self.mouse(.mouseMoved, at: 1)) == .programmatic)
        #expect(FocusEvent.Source.of(nil) == .programmatic, "a CLI or socket run has no input device")
    }

    @Test func aContextMenuItemChosenWithReturnIsKeyboard() throws {
        let tap = InputEventTap()
        let rightDown = try Self.mouse(.rightMouseDown, at: 10)
        tap.deliverObserve(rightDown)
        // The menu tracks inside the right-click's dispatch and dequeued Return itself.
        let chosen = InputEventTap.actionEvent(dispatched: rightDown, lastDispatched: tap.lastDispatched,
                                               tracking: try Self.key(at: 11))
        #expect(FocusEvent.Source.of(chosen) == .keyboard)
    }

    @Test func aRunAfterAClickIsNotTheMouse() throws {
        let tap = InputEventTap()
        let click = try Self.mouse(.leftMouseDown, at: 20)
        tap.deliverObserve(click)
        let after = InputEventTap.actionEvent(dispatched: nil, lastDispatched: tap.lastDispatched, tracking: click)
        #expect(FocusEvent.Source.of(after) == .programmatic)
        #expect(FocusEvent.Source.intent == .cli, "outside any dispatch a user-invoked change is the CLI's")
    }

    private static func key(at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                             windowNumber: 0, context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private static func mouse(_ type: NSEvent.EventType, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp,
                                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
