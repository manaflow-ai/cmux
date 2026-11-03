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
}
