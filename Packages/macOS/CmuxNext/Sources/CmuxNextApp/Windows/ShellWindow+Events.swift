import AppKit
import CmuxNextDesign

extension ShellWindow {
    /// The window's one titlebar decision (`TitlebarDragPolicy`): a left
    /// mouse-down in the band is delivered as usual, then moves the window
    /// only when the policy says so; a double-click only runs the titlebar action (delivered, it zoomed twice: cosmic-gray 10-13).
    /// A pane's cursor-rect policy (`cursorRectHold`) sees every event first. An Option-press on a
    /// top-row tab bar's empty space drags its pane instead (`PaneSwapDrag`).
    override func sendEvent(_ event: NSEvent) {
        cursorRectHold?.windowWillSend(event, in: self)
        // A press in a workspace shown beside the focused one (`sidebar.multiView`) focuses it before it lands there.
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: (windowController as? WindowController)?.focusOnScreenWorkspace(at: event.locationInWindow)
        default: break
        }
        guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control), // control-press: a right-click
              TitlebarDragPolicy.decide(at: event.locationInWindow, in: self) == .movesWindow, !PaneSwapDrag.claims(event, in: self) else {
            return super.sendEvent(event)
        }
        if event.clickCount != 2 { super.sendEvent(event) }
        WindowTitlebar.handleMouseDown(event, in: self)
    }

    /// The pane policy may keep an invalidation for later (`CursorRectHoldPolicy`); every other
    /// invalidation is AppKit's as before.
    override func invalidateCursorRects(for view: NSView) {
        if cursorRectHold?.holdsInvalidation(for: view, in: self) == true { return }
        super.invalidateCursorRects(for: view)
    }

    /// AppKit ends an edit by removing its field editor, and the responder change that follows
    /// reached the focus model inside that teardown. When the model still wanted an address bar
    /// whose pane was moving (header [+] beside a browser), it put the responder back on the field,
    /// which began an edit inside the one ending; that edit's end did the same, until the
    /// main-thread watchdog stopped the app (cx-p0fz). The focus model hears of changes made
    /// during the teardown once, when the outermost `endEditing(for:)` returns.
    override func endEditing(for object: Any?) {
        editTeardown.depth += 1
        super.endEditing(for: object)
        editTeardown.depth -= 1
        guard editTeardown.depth == 0, editTeardown.pending else { return }
        editTeardown.pending = false
        reportResponder()
    }

    /// Tells the focus model the first responder changed, or holds that for the edit's end.
    func reportResponder() {
        guard editTeardown.depth == 0 else {
            editTeardown.pending = true
            return
        }
        guard let controller = windowController as? WindowController else { return }
        controller.focus.responderDidChange(FocusResponderClassifier.classify(firstResponder, in: controller), source: .current)
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
