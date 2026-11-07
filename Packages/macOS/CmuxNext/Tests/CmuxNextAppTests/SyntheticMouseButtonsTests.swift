import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import Testing

/// A synthesized press (`debug.mouse`, a capture's drag) holds its button from its mouse-down to its mouse-up, as the
/// hardware does. WebKit and Chromium take a pointer event's `buttons` from `NSEvent.pressedMouseButtons`, not from
/// the event, so a page's drag that ends on a move with no button (the sidebar's Updated card) ended at the first
/// synthesized move and the press selected text instead.
@MainActor @Suite(.serialized)
struct SyntheticMouseButtonsTests {
    private static func event(_ type: NSEvent.EventType, at time: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: time, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1,
            pressure: [.leftMouseUp, .rightMouseUp].contains(type) ? 0 : 1))
    }

    @Test func aSyntheticLeftPressHoldsButtonOneUntilItsRelease() throws {
        let base = 900_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        let dragged = try Self.event(.leftMouseDragged, at: base + 0.01)
        let up = try Self.event(.leftMouseUp, at: base + 0.02)
        SyntheticInput.register([down, dragged, up])
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "a press only posted, not dispatched yet, holds no button")
        #expect(!SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 1, "a synthetic mouse-down left button 1 up")
        #expect(!SyntheticInput.isUserInput(dragged))
        #expect(NSEvent.pressedMouseButtons & 1 == 1, "a synthetic drag move let button 1 go")
        #expect(!SyntheticInput.isUserInput(up))
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "a synthetic mouse-up kept button 1 held")
    }

    @Test func aSyntheticRightPressHoldsButtonTwo() throws {
        let base = 901_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.rightMouseDown, at: base)
        let up = try Self.event(.rightMouseUp, at: base + 0.01)
        SyntheticInput.register([down, up])
        #expect(!SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 2 == 2, "a synthetic right mouse-down left button 2 up")
        #expect(!SyntheticInput.isUserInput(up))
        #expect(NSEvent.pressedMouseButtons & 2 == 0, "a synthetic right mouse-up kept button 2 held")
    }

    /// A native control's tracking loop takes a click's mouse-up from the queue itself, so `sendEvent` never sees
    /// it: the next synthetic event that does arrive lets go of the button that release would have.
    @Test func aReleaseATrackingLoopTookLetsGoAtTheNextSyntheticEvent() throws {
        let base = 903_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        let up = try Self.event(.leftMouseUp, at: base + 0.01)
        let moved = try Self.event(.mouseMoved, at: base + 0.02)
        SyntheticInput.register([down, up, moved])
        #expect(!SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 1)
        #expect(!SyntheticInput.isUserInput(moved))
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "a click whose release a tracking loop took kept button 1 held")
    }

    /// The person's own press is the hardware's to report: one that was never registered changes nothing.
    @Test func thePersonsOwnPressHoldsNoSyntheticButton() throws {
        let base = 902_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        #expect(SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "the person's press set the synthetic button")
    }
}
