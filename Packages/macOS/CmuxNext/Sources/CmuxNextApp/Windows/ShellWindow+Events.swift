import AppKit
import CmuxNextDesign

extension ShellWindow {
    /// The window's one titlebar decision (`TitlebarDragPolicy`): a left
    /// mouse-down in the band is delivered as usual, then moves the window
    /// (or runs the double-click action) only when the policy says so.
    /// A pane's cursor-rect policy (`cursorRectHold`) sees every event first.
    override func sendEvent(_ event: NSEvent) {
        cursorRectHold?.windowWillSend(event, in: self)
        guard event.type == .leftMouseDown, TitlebarDragPolicy.decide(at: event.locationInWindow, in: self) == .movesWindow else {
            return super.sendEvent(event)
        }
        super.sendEvent(event)
        WindowTitlebar.handleMouseDown(event, in: self)
    }

    /// The pane policy may keep an invalidation for later (`CursorRectHoldPolicy`); every other
    /// invalidation is AppKit's as before.
    override func invalidateCursorRects(for view: NSView) {
        if cursorRectHold?.holdsInvalidation(for: view, in: self) == true { return }
        super.invalidateCursorRects(for: view)
    }

    override func becomeKey() {
        cursorRectHold?.windowKeyStateWillChange(self)
        super.becomeKey()
    }

    override func resignKey() {
        cursorRectHold?.windowKeyStateWillChange(self)
        super.resignKey()
    }
}
