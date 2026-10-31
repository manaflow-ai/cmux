import AppKit
import CmuxNextDesign

extension ShellWindow {
    /// The window's one titlebar decision (`TitlebarDragPolicy`): a left
    /// mouse-down in the band is delivered as usual, then moves the window
    /// only when the policy says so; a double-click only runs the titlebar action (delivered, it zoomed twice: cosmic-gray 10-13).
    /// A pane's cursor-rect policy (`cursorRectHold`) sees every event first. An Option-press on a
    /// top-row tab bar's empty space drags its pane instead (`PaneSwapDrag`).
    override func sendEvent(_ event: NSEvent) {
        // A press while this window's Chromium page, a panel or no window holds the key acts at once (`FirstClickPolicy`):
        // made key first, AppKit gives the press to the view under it instead of spending it on making the window key.
        if FirstClickPolicy().takesFirstClick(event, in: self, keyWindow: NSApp.keyWindow, mainWindow: NSApp.mainWindow,
                                              appIsActive: NSApp.isActive, appIsModal: NSApp.modalWindow != nil) { makeKey() }
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

    /// A responder change reported inside an edit's teardown let the focus model put the responder
    /// back on a moving address bar, beginning an edit inside the one ending, until the watchdog
    /// stopped the app (cx-p0fz); the focus model hears of the teardown's changes once, at its end.
    override func endEditing(for object: Any?) { holdingResponderReports { super.endEditing(for: object) } }

    /// Runs `body` (an edit's end, a `makeFirstResponder`); its responder changes are reported once, at the outermost end.
    func holdingResponderReports<T>(_ body: () -> T) -> T {
        editTeardown.depth += 1
        let result = body()
        editTeardown.depth -= 1
        if editTeardown.depth == 0, editTeardown.pending { editTeardown.pending = false; BenchSpans.measure("focus.reportResponder") { reportResponder() } }
        return result
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
