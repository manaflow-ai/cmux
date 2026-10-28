import AppKit
import CmuxNextDesign
import CmuxNextFeatures
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
        // A hover under an overlay of the window's top layer reaches only the overlay (feature `overlayTopLayer`).
        if WindowOverlayHost.isCoverableHover(event.type), WindowOverlayHost.existingHost(for: self)?.routeCoveredHover(event) == true { return }
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

    // MARK: Order-in (QA chrome-parity-v2-1 bug 1)

    /// The first time a window is placed on screen with no first responder, AppKit makes its first key view the
    /// first responder (`initialFirstResponder` unset). In a cmux window that is the sidebar's workspace list
    /// whenever the focused pane's content is not a key view yet (a restored browser pane showing its launch
    /// picture): the focus model heard a sidebar report, took it as the person's choice, and the next Return
    /// opened the workspace's rename field. Nobody asked for that pick. While the window is ordered in with no
    /// first responder, only the focus model's own move (its applier) takes the keyboard; it places the keyboard
    /// on the restored target once that content is presented. A responder already set is left alone.
    func refusesOrderInKeyView(_ responder: NSResponder?) -> Bool {
        guard orderInDepth > 0, firstResponder === self, let view = responder as? NSView, view.window === self else { return false }
        return focus?.isApplying != true
    }

    /// Runs `body` with `orderInDepth` counted when the window is not on screen yet (every ordering path below).
    private func orderingIn(_ body: () -> Void) {
        guard !isVisible else { return body() }
        orderInDepth += 1
        defer { orderInDepth -= 1 }
        body()
    }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place != .out else { return super.order(place, relativeTo: otherWin) }
        orderingIn { super.order(place, relativeTo: otherWin) }
    }

    override func orderFront(_ sender: Any?) { orderingIn { super.orderFront(sender) } }
    override func orderBack(_ sender: Any?) { orderingIn { super.orderBack(sender) } }
    override func orderFrontRegardless() { orderingIn { super.orderFrontRegardless() } }
    override func makeKeyAndOrderFront(_ sender: Any?) { orderingIn { super.makeKeyAndOrderFront(sender) } }

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

/// Its reorder drags (tab strip, sidebar rows and spaces, extension buttons) move once per frame on the app's
/// coalescers (feature `pointerFrameDrags`), read on each press (``PointerFrameDrag``).
extension ShellWindow: DragFrameInputHosting {
    var dragFrameInput: FrameInputCoalescers? { (windowController as? WindowController)?.services.dragFrameInput }
}

/// Its find pills hold the app's input tap `findPillOpen` flag while their field edits, so a key-down
/// asks no responder whether a pill takes it (`FindPillView.forwardArrowKeyDownToEditingPill`).
extension ShellWindow: InputTapHosting {
    var inputTap: InputEventTap? { (windowController as? WindowController)?.services.inputTap }
}

/// Its terminals and omnibar field editor time their input method calls in the key's latency slot
/// (`TextInputStage`), read when they join the window.
extension ShellWindow: TextInputStageHosting {
    var textInputStage: TextInputStage? { (windowController as? WindowController)?.services.inputLatency.textInput }
}

/// Overlays draw in the window's own top layer while no page child window shows (feature `overlayTopLayer`),
/// read when the overlay host is made. A modal there keeps the keys it had in the panel:
/// the window routes keys as a panel over itself while ``overlayHasKeyboard`` holds (`KeyRouter.focus(for:)`),
/// and a field editor's Tab cycles inside the modal.
extension ShellWindow: OverlayTopLayerHosting {
    var overlaysInTopLayer: Bool { (windowController as? WindowController)?.services.features.isEnabled(.overlayTopLayer) == true }

    /// An overlay control of the top layer has the keyboard: no content shortcut runs below it.
    var overlayHasKeyboard: Bool { WindowOverlayHost.existingHost(for: self)?.keyboardIsInWindowTopLayer == true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A panel over this window has the keys: no Ghostty keybind below (`KeyRouter.overlayHasKeys`).
        if !isKeyWindow, let focus, KeyRouter.overlayHasKeys(focus.state) { return false }
        // A modal of the top layer has the keys: only the top layer sees them, as only the key panel did; the
        // content below (an empty workspace's Return) never does. The main menu still comes after.
        if let host = WindowOverlayHost.existingHost(for: self), host.keyboardIsInWindowTopLayer {
            return host.topLayer.performKeyEquivalent(with: event)
        }
        if let keyRouter, let focus, keyRouter.routeContentKeyEquivalent(event, focus: focus.state) { return true }
        // A chord the dispatcher decided for a focused terminal or page, or a field in a pane: that surface or pane answers.
        if let surface = keyRouter?.directKeyEquivalentTarget(for: event, firstResponder: firstResponder) {
            return surface.performKeyEquivalent(with: event)
        }
        return super.performKeyEquivalent(with: event)
    }

    override func selectNextKeyView(_ sender: Any?) {
        if WindowOverlayHost.existingHost(for: self)?.cycleKeyViewInWindowTopLayer(forward: true) != true { super.selectNextKeyView(sender) }
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        if WindowOverlayHost.existingHost(for: self)?.cycleKeyViewInWindowTopLayer(forward: false) != true { super.selectPreviousKeyView(sender) }
    }
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
