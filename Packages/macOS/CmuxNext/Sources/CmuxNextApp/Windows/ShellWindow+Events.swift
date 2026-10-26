import AppKit
import CmuxNextDesign
import CmuxNextInput
import CmuxNextWakeups

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

/// Its overlay host, thin scrollers, hover reveals and hover cards hover once per frame on the app's
/// coalescers (feature `pointerFrameHover`), read when they join the window.
extension ShellWindow: HoverFrameInputHosting {
    var hoverFrameInput: FrameInputCoalescers? { (windowController as? WindowController)?.services.hoverFrameInput }
}

/// The window's child windows: content children (page windows in process, content panels on either
/// page surface) keep the overlay layer's placement and the overlay host's order current as they come and go.
extension ShellWindow {
    /// The Chromium fork adds each page window as a child ordered above
    /// everything, the overlay panel included. Lift the overlay (and the app
    /// panels above it) in the same call, before the window server shows a
    /// frame with the page over the focus ring; the notifications that
    /// follow the page would come a frame late.
    override func addChildWindow(_ childWin: NSWindow, ordered place: NSWindow.OrderingMode) {
        // Only the overlay host panel and page windows belong here (debug and test builds record the rest).
        ChildWindowPolicy.check(childWin, parent: self)
        super.addChildWindow(childWin, ordered: place)
        if WindowOverlayLayer.isContent(childWin, of: self) { overlayLayer.evaluate() }
        WindowOverlayHost.childWindowsDidChange(of: self)
    }

    /// A content child left (a page popup closed: `removeChildWindow`, then `orderOut`): the planes go
    /// back into the view tree in the same call. With pages in the view tree no other window's notice
    /// is watched, so nothing else would tell the overlay layer.
    override func removeChildWindow(_ childWin: NSWindow) {
        let wasContent = childWin.parent === self && WindowOverlayLayer.isContent(childWin, of: self)
        super.removeChildWindow(childWin)
        if wasContent { overlayLayer.evaluate() }
    }
}
