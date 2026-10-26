import AppKit
import CmuxNextFocusUI
import Testing

/// ``InputDispatchContext``: nested dispatches (a synthetic event sent from inside another dispatch, as
/// `DebugNativeInput.sendThroughApp` does) report the innermost event, the outer one again after it, and none
/// after the last one ends.
@MainActor @Suite
struct InputDispatchContextTests {
    private static func event(_ type: NSEvent.EventType, at timestamp: TimeInterval) throws -> NSEvent {
        _ = NSApplication.shared
        if type == .keyDown {
            return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: timestamp,
                                                 windowNumber: 0, context: nil, characters: "a", charactersIgnoringModifiers: "a",
                                                 isARepeat: false, keyCode: 0))
        }
        return try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: timestamp, windowNumber: 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func nestedDispatchesReportTheInnermostEvent() throws {
        let context = InputDispatchContext()
        let click = try Self.event(.leftMouseDown, at: 1)
        let key = try Self.event(.keyDown, at: 2)
        #expect(context.event == nil)
        context.dispatching(click) {
            #expect(context.event === click)
            #expect(!context.isKeyDown)
            context.dispatching(key) {
                #expect(context.event === key)
                #expect(context.isKeyDown)
            }
            #expect(context.event === click)
        }
        #expect(context.event == nil)
        #expect(!context.isKeyDown)
    }

    /// A switch begun now takes the key or click being dispatched as its input; a mouse move is none, and nothing
    /// is between dispatches (`NSApp.currentEvent` keeps the last event after its dispatch ends).
    @Test func theSwitchInputIsTheDispatchedKeyOrClick() throws {
        let context = InputDispatchContext()
        let click = try Self.event(.leftMouseUp, at: 7)
        let key = try Self.event(.keyDown, at: 8)
        let moved = try Self.event(.mouseMoved, at: 9)
        #expect(context.inputTimestamp == nil)
        context.dispatching(click) {
            #expect(context.inputTimestamp == 7)
            context.dispatching(key) { #expect(context.inputTimestamp == 8) }
            context.dispatching(moved) { #expect(context.inputTimestamp == nil) }
        }
        #expect(context.inputTimestamp == nil, "after the dispatch ends, a later switch has no input")
    }
}
