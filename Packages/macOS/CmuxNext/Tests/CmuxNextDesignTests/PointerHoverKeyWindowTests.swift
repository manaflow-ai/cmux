import AppKit
@testable import CmuxNextDesign
import Testing

/// `PointerHover` observes the app's key-window changes once for every target (its index's
/// `MainActorObservation` tokens). A key change files every target under its window again and
/// recomputes that window's hover, and a closed window drops its synthesized pointer. Each test
/// posts the notification AppKit posts, on the center the tokens observe, so no screen or active
/// app is needed.
@MainActor
@Suite(.serialized) struct PointerHoverKeyWindowTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func center(of view: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    /// A target whose eligibility changed with no `refresh()` of its own is read again when its
    /// window becomes or resigns key, in the post's own turn.
    @Test func aKeyChangeRecomputesTheWindowsHover() {
        let window = Self.window()
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 40))
        window.contentView?.addSubview(view)
        var hoverable = false
        var changes: [Bool] = []
        let hover = PointerHover(view) { changes.append($0) }
        hover.isHoverable = { hoverable }
        PointerHover.setDebugPointer(Self.center(of: view), in: window)
        #expect(!hover.isHovering, "a target that is not hoverable hovers")

        hoverable = true
        #expect(!hover.isHovering, "the target was read again with no refresh")
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        #expect(hover.isHovering, "the window becoming key did not recompute its hover")

        hoverable = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(!hover.isHovering, "the window resigning key did not recompute its hover")
        #expect(changes == [true, false])

        let key = ObjectIdentifier(window)
        #expect(PointerHover.debugPointers[key] != nil)
        window.close()
        #expect(PointerHover.debugPointers[key] == nil, "a closed window kept its synthesized pointer")
    }

    /// A view moved straight from one window to another (no refresh between) is not filed under
    /// the new window, so that window's refresh misses it; the new window becoming key files it
    /// there and lights it.
    @Test func aKeyChangeFindsAViewThatMovedToTheWindow() {
        let first = Self.window()
        let second = Self.window()
        defer {
            first.close()
            second.close()
        }
        let view = NSView(frame: NSRect(x: 20, y: 20, width: 100, height: 40))
        first.contentView?.addSubview(view)
        let hover = PointerHover(view)

        view.removeFromSuperview()
        second.contentView?.addSubview(view)
        PointerHover.setDebugPointer(Self.center(of: view), in: second)
        #expect(!hover.isHovering, "a refresh of the new window found a target filed under its old window")

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(hover.isHovering, "the new window becoming key did not find the view that moved there")
        PointerHover.setDebugPointer(nil, in: second)
        #expect(!hover.isHovering)
    }
}
