import AppKit
@testable import CmuxNextDesign
import Testing

/// A chrome button that moves to another window under a still pointer (a band button that moves
/// into fullscreen's toolbar window, a strip button that moves with Move Tab or Pane to New
/// Window) gets no enter there: the hover owner keeps no index of windows, so the button
/// recomputes its own target from `viewDidMoveToWindow`. Before, it lit only on the new
/// window's next mouse move.
///
/// The synthesized pointer is pinned (`followsRealMouse: false`) and set before the move, so the
/// window's own refresh runs while the button is not there yet.
@MainActor
struct PointerHoverWindowMoveTests {
    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Moves `button` from one window into another whose pointer is over the button's frame
    /// there, and returns whether it hovers after the move.
    private static func hoversAfterMove(_ button: NSButton, pointer: () -> PointerHover?) -> Bool {
        let from = window(), to = window()
        defer {
            PointerHover.debugPointers[ObjectIdentifier(from)] = nil
            PointerHover.debugPointers[ObjectIdentifier(to)] = nil
            from.close()
            to.close()
        }
        button.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        from.contentView?.addSubview(button)
        PointerHover.setDebugPointer(nil, in: from, followsRealMouse: false)
        #expect(pointer()?.isHovering == false)
        PointerHover.setDebugPointer(NSPoint(x: 22, y: 22), in: to, followsRealMouse: false)
        to.contentView?.addSubview(button)
        return pointer()?.isHovering ?? false
    }

    @Test func aBandButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = TitlebarBandButton(symbol: "sidebar.left")
        #expect(Self.hoversAfterMove(button) { button.hover.pointer })
    }

    @Test func anOverflowButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = OverflowButton(label: "More")
        #expect(Self.hoversAfterMove(button) { button.hover.pointer })
    }
}
