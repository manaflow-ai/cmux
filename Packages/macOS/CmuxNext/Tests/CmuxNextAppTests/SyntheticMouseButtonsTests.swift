import AppKit
@testable import CmuxNextApp
import CmuxNextCompat
import CmuxNextFocusUI
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

    /// An `otherMouse` event of `button` (2 middle, 3 and up the extra buttons): `NSEvent.mouseEvent` leaves
    /// buttonNumber 0, so it is set on a copy, as `DebugMouse` does.
    private static func other(_ type: NSEvent.EventType, button: Int64, at time: TimeInterval) throws -> NSEvent {
        let cg = try #require(try event(type, at: time).cgEvent?.copy())
        cg.setIntegerValueField(.mouseEventButtonNumber, value: button)
        return try #require(NSEvent(cgEvent: cg))
    }

    /// The no-activate guard's host with AppKit's input state; the rest faked so nothing really deactivates.
    @MainActor private final class AppKitButtonsHost: NoActivateKeyboardGuard.Host {
        let appKit = AppKitKeyboardGuardHost()
        var mouseButtonDown: Bool { appKit.mouseButtonDown }
        var commandHeld = false
        var isAppActive = true
        var now: ContinuousClock.Instant = .now
        var gaveBack = false
        func schedule(after delay: Duration, _ body: @escaping @MainActor @Sendable () -> Void) {}
        func giveActivationBack(to app: NSRunningApplication?) { gaveBack = true }
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

    /// The event queue keeps a posted event's timestamp to the nanosecond: the event that arrives is stamped a
    /// fraction of a nanosecond off the one registered (1269102.0579499167 posted, 1269102.057949916 dispatched, in
    /// a capture's log). It is still the synthetic press, and its button is held.
    @Test func aPressStampedToTheNanosecondInTheQueueIsStillSynthetic() throws {
        let base = 904_000.0579499167 + Double(Int.random(in: 0..<1000))
        let posted = try Self.event(.leftMouseDown, at: base)
        let dispatched = try Self.event(.leftMouseDown, at: (base * 1e9).rounded(.down) / 1e9)
        let up = try Self.event(.leftMouseUp, at: base + 0.01)
        SyntheticInput.register([posted, up])
        #expect(!SyntheticInput.isUserInput(dispatched), "a press stamped to the nanosecond read as the person's")
        #expect(NSEvent.pressedMouseButtons & 1 == 1)
        #expect(!SyntheticInput.isUserInput(up))
        #expect(NSEvent.pressedMouseButtons & 1 == 0)
    }

    /// A synthetic press is not the person choosing cmux: an activation nobody asked for while an
    /// agent's press holds its button still goes back. The guard reads the hardware's buttons only.
    @Test func anActivationDuringASyntheticHoldIsStillGivenBack() throws {
        let base = 905_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        let up = try Self.event(.leftMouseUp, at: base + 0.01)
        SyntheticInput.register([down, up])
        #expect(!SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 1)
        let host = AppKitButtonsHost()
        let guardian = NoActivateKeyboardGuard(host: host, frontmost: NSRunningApplication.current, frontmostPID: 4242)
        guardian.start()
        #expect(!host.mouseButtonDown, "the guard saw the synthetic press as a held hardware button")
        #expect(host.gaveBack, "an activation during a synthetic hold was kept as the person's choice")
        #expect(!SyntheticInput.isUserInput(up))
    }

    /// A tracking loop took the press's mouse-up and no synthetic event follows: the person's own next
    /// mouse event, with no hardware button down, lets go of the synthetic button, so hover and
    /// focus-follows-mouse don't see a press that never ends.
    @Test func thePersonsNextMouseEventLetsGoOfAPressWhoseReleaseWasEaten() throws {
        let base = 906_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        let up = try Self.event(.leftMouseUp, at: base + 0.01)
        SyntheticInput.register([down, up])
        #expect(!SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 1)
        let moved = try Self.event(.mouseMoved, at: base + 0.05)
        #expect(SyntheticInput.isUserInput(moved))
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "a mouse-up a tracking loop took kept button 1 held for good")
    }

    /// Each extra button has its own bit: an eaten release of button 3 lets go of button 3, not the middle one.
    @Test func anEatenReleaseOfAnExtraButtonLetsGoOfThatButtonOnly() throws {
        let base = 907_000 + Double.random(in: 0..<1000)
        let middle = try Self.other(.otherMouseDown, button: 2, at: base)
        let extra = try Self.other(.otherMouseDown, button: 3, at: base + 0.01)
        let extraUp = try Self.other(.otherMouseUp, button: 3, at: base + 0.02)
        let moved = try Self.event(.mouseMoved, at: base + 0.03)
        let middleUp = try Self.other(.otherMouseUp, button: 2, at: base + 0.04)
        SyntheticInput.register([middle, extra, extraUp, moved, middleUp])
        #expect(!SyntheticInput.isUserInput(middle))
        #expect(!SyntheticInput.isUserInput(extra))
        #expect(NSEvent.pressedMouseButtons & 0b1100 == 0b1100)
        #expect(!SyntheticInput.isUserInput(moved))
        #expect(NSEvent.pressedMouseButtons & 8 == 0, "button 3's eaten release kept it held")
        #expect(NSEvent.pressedMouseButtons & 4 == 4, "button 3's eaten release let go of the middle button")
        #expect(!SyntheticInput.isUserInput(middleUp))
        #expect(NSEvent.pressedMouseButtons & 0b1100 == 0)
    }

    /// The buttons a view reads as it takes a press and its release.
    private final class ButtonsReadingView: NSView {
        var readAtDown: Int?
        var readAtUp: Int?
        override func mouseDown(with event: NSEvent) { readAtDown = NSEvent.pressedMouseButtons }
        override func mouseUp(with event: NSEvent) { readAtUp = NSEvent.pressedMouseButtons }
    }

    /// A click handed straight to a page's view (`debug.mouse` target page, the agent pane's click) holds its
    /// button while the view takes the press and lets go before it takes the release, as one through the app does.
    @Test func aClickHandedStraightToAViewHoldsItsButtonUntilTheRelease() throws {
        let base = 908_000 + Double.random(in: 0..<1000)
        let view = ButtonsReadingView()
        SyntheticInput.click(view, down: try Self.event(.leftMouseDown, at: base),
                             up: try Self.event(.leftMouseUp, at: base + 0.01))
        #expect(view.readAtDown.map { $0 & 1 } == 1, "the view took the press with no button held")
        #expect(view.readAtUp.map { $0 & 1 } == 0, "the view took the release with button 1 still held")
        #expect(NSEvent.pressedMouseButtons & 1 == 0)
    }

    /// A click handed straight to a view doesn't touch another caller's posted events still in the queue: a
    /// `debug.mouse` press registered before it stays synthetic and holds its button when it arrives, and the direct
    /// click's release doesn't let go of it.
    @Test func aDirectClickLeavesAQueuedPressSynthetic() throws {
        let base = 909_000 + Double.random(in: 0..<1000)
        let queued = try Self.event(.leftMouseDown, at: base)
        let queuedUp = try Self.event(.leftMouseUp, at: base + 0.5)
        SyntheticInput.register([queued, queuedUp])
        let view = ButtonsReadingView()
        SyntheticInput.click(view, down: try Self.event(.leftMouseDown, at: base + 0.1),
                             up: try Self.event(.leftMouseUp, at: base + 0.11))
        #expect(view.readAtDown.map { $0 & 1 } == 1)
        #expect(!SyntheticInput.isUserInput(queued), "the queued press read as the person's after a direct click")
        #expect(NSEvent.pressedMouseButtons & 1 == 1, "the queued press holds no button")
        #expect(!SyntheticInput.isUserInput(queuedUp))
        #expect(NSEvent.pressedMouseButtons & 1 == 0)
    }

    /// A direct click while a posted press holds button 1 (a capture's drag left open): the click's release lets go
    /// of its own hold only, so the drag's button stays down.
    @Test func aDirectClickDuringAHeldDragKeepsTheDragsButton() throws {
        let base = 910_000 + Double.random(in: 0..<1000)
        let drag = try Self.event(.leftMouseDown, at: base)
        let dragUp = try Self.event(.leftMouseUp, at: base + 0.5)
        SyntheticInput.register([drag, dragUp])
        #expect(!SyntheticInput.isUserInput(drag))
        SyntheticInput.click(ButtonsReadingView(), down: try Self.event(.leftMouseDown, at: base + 0.1),
                             up: try Self.event(.leftMouseUp, at: base + 0.11))
        #expect(NSEvent.pressedMouseButtons & 1 == 1, "a direct click's release let go of a held drag")
        #expect(!SyntheticInput.isUserInput(dragUp))
        #expect(NSEvent.pressedMouseButtons & 1 == 0)
    }

    /// The person's own press is the hardware's to report: one that was never registered changes nothing.
    @Test func thePersonsOwnPressHoldsNoSyntheticButton() throws {
        let base = 902_000 + Double.random(in: 0..<1000)
        let down = try Self.event(.leftMouseDown, at: base)
        #expect(SyntheticInput.isUserInput(down))
        #expect(NSEvent.pressedMouseButtons & 1 == 0, "the person's press set the synthetic button")
    }
}
