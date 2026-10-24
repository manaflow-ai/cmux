import AppKit
@testable import CmuxNextDesign
import Testing

/// A hover owner that moves to another window under a still pointer (a band button that moves into
/// fullscreen's toolbar window, a strip or toast control that moves with Move Tab or Pane to New
/// Window) gets no enter there, and the hover index still files its target under the old window, so
/// the new window's refreshes do not find it: it lit only on the next mouse move or key change.
/// Every owner recomputes its own target from `viewDidMoveToWindow` through one shared helper
/// (`PointerHover.ownerDidMoveToWindow`, `ChromeHover.viewDidMoveToWindow`).
@MainActor @Suite(.serialized) struct PointerHoverOwnerWindowMoveTests {
    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// Moves `view` from one window into another whose pointer is over the view's frame there, and
    /// returns whether it hovers after the move. The pointer is set before the move, so the new
    /// window's own refresh runs while the view is not there yet.
    static func hoversAfterMove(_ view: NSView, isHovering: () -> Bool) -> Bool {
        let from = window(), to = window()
        defer {
            PointerHover.debugPointers[ObjectIdentifier(from)] = nil
            PointerHover.debugPointers[ObjectIdentifier(to)] = nil
            from.close()
            to.close()
        }
        view.frame = NSRect(x: 10, y: 10, width: 24, height: 24)
        from.contentView?.addSubview(view)
        PointerHover.setDebugPointer(nil, in: from)
        #expect(!isHovering())
        PointerHover.setDebugPointer(NSPoint(x: 22, y: 22), in: to)
        to.contentView?.addSubview(view)
        return isHovering()
    }

    @Test func aBandButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = TitlebarBandButton(symbol: "sidebar.left")
        #expect(Self.hoversAfterMove(button) { button.hover.state.hovering })
    }

    @Test func anOverflowButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = OverflowButton(label: "More")
        #expect(Self.hoversAfterMove(button) { button.hover.state.hovering })
    }

    @Test func aToastButtonMovedUnderAStillPointerHoversAtOnce() {
        let button = CmuxToastButton(style: .action, title: "Undo", target: nil, action: nil)
        #expect(Self.hoversAfterMove(button) { button.hover.state.hovering })
    }

    @Test func aToastMovedUnderAStillPointerHoversAtOnce() {
        let toast = CmuxToastView(toast: CmuxToast(id: "moved", message: "Saved"))
        #expect(Self.hoversAfterMove(toast) { toast.isHovered })
    }
}
