import AppKit
import CmuxNextDesign

/// A presented page's input surface (``CEFHostedPageView/input`` set; ``InTreePages/Presentation/presented``). The page
/// window is headless and the WindowServer sends it nothing, so every event the person aims at the page comes here and
/// goes on as ``ChromiumPageInput``. With no input (a child-window page) every handler leaves the event to AppKit's
/// default, and the page window above takes it instead.
extension CEFHostedPageView {
    override var acceptsFirstResponder: Bool { input != nil }
    /// Not a stop of the window's keyboard loop: the page's own Tab order runs inside the page.
    override var canBecomeKeyView: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { input != nil }

    // MARK: Focus

    /// The page takes the keyboard: Chromium's page focus and active state, with no window made key
    /// (`cmux_shim_browser_set_page_focus`). The page has focus while this view is its key window's first responder
    /// (`cmux_browser_set_embedder_active`'s contract), as a Chrome page has while its view is first responder of a key
    /// window: the window resigning key blurs the page, and becoming key again focuses it.
    override func becomeFirstResponder() -> Bool {
        guard input != nil else { return super.becomeFirstResponder() }
        syncPageFocus(firstResponder: true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard input != nil else { return super.resignFirstResponder() }
        syncPageFocus(firstResponder: false)
        return true
    }

    /// Gives the page the focus this view's state says, when it changed (`firstResponder`: the state AppKit is moving
    /// to, inside a responder change; nil reads the window's).
    func syncPageFocus(firstResponder: Bool? = nil) {
        guard let input else { return }
        let responder = firstResponder ?? (window?.firstResponder === self)
        let focused = responder && window.map(windowIsKey) == true
        guard focused != givesPageFocus else { return }
        givesPageFocus = focused
        input.focusChanged(focused)
    }

    /// cmux grants the page the keyboard again while this view is already first responder: Chromium may have dropped
    /// the page's focus meanwhile (a hide), so it is given again.
    func reassertPageFocus() {
        guard let input else { return }
        givesPageFocus = window?.firstResponder === self && window.map(windowIsKey) == true
        if givesPageFocus { input.focusChanged(true) }
    }

    /// cmux takes the keyboard from the page while this view stays first responder.
    func dropPageFocus() {
        guard let input, givesPageFocus else { return }
        givesPageFocus = false
        input.focusChanged(false)
    }

    /// Follows the window's key changes while this view presents a page.
    func observeWindowKey() {
        let center = NotificationCenter.default
        if let observedWindow {
            center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: observedWindow)
            center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        observedWindow = nil
        guard input != nil, let window else {
            if input != nil { syncPageFocus(firstResponder: false) }
            return
        }
        observedWindow = window
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
        center.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: NSWindow.didResignKeyNotification, object: window)
        syncPageFocus()
    }

    /// AppKit posts a window's key changes on the main thread.
    @objc func windowKeyChanged(_ note: Notification) {
        syncPageFocus()
    }

    // MARK: Mouse

    /// Its own tracking area only where no layout screen serves it (``PanePointerFollowing``): in a pane the screen's
    /// one area delivers its moves, so a page that moves with its pane costs AppKit no tracking-area work (RESIZE MAIN
    /// BUDGET), as for the helper app's page view.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        trackingArea = nil
        guard input != nil, !isServedByPanePointerArea else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        guard input != nil else { return super.mouseDown(with: event) }
        takeKeyboardOnPress()
        forward(event, .down, button: 0)
    }

    override func mouseUp(with event: NSEvent) {
        guard input != nil else { return super.mouseUp(with: event) }
        forward(event, .up, button: 0)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard input != nil else { return super.rightMouseDown(with: event) }
        takeKeyboardOnPress()
        forward(event, .down, button: 2)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard input != nil else { return super.rightMouseUp(with: event) }
        forward(event, .up, button: 2)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard input != nil else { return super.otherMouseDown(with: event) }
        forward(event, .down, button: 1)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard input != nil else { return super.otherMouseUp(with: event) }
        forward(event, .up, button: 1)
    }

    override func mouseMoved(with event: NSEvent) {
        guard input != nil else { return super.mouseMoved(with: event) }
        forward(event, .move, button: 0)
    }

    override func mouseDragged(with event: NSEvent) {
        guard input != nil else { return super.mouseDragged(with: event) }
        forward(event, .move, button: 0)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard input != nil else { return super.rightMouseDragged(with: event) }
        forward(event, .move, button: 2)
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard input != nil else { return super.otherMouseDragged(with: event) }
        forward(event, .move, button: 1)
    }

    override func mouseEntered(with event: NSEvent) {
        guard input != nil else { return super.mouseEntered(with: event) }
        pointerInside = true
        forward(event, .move, button: 0)
        showPageCursor()
    }

    override func mouseExited(with event: NSEvent) {
        guard input != nil else { return super.mouseExited(with: event) }
        pointerInside = false
        forward(event, .exit, button: 0)
    }

    override func scrollWheel(with event: NSEvent) { // perf-hot: 5us cef-host-input (every scroll event)
        guard let input else { return super.scrollWheel(with: event) }
        input.send(ChromiumPageInput.wheel(event, in: self))
    }

    /// A press makes the page view its window's first responder, as a press in Chrome's page view does (AppKit made it
    /// first responder already when the window was key; an inactive window's first press comes here first).
    private func takeKeyboardOnPress() {
        guard let window, window.firstResponder !== self else { return }
        FocusRoute(.person, "a press on a presented page").moveKeyboard(in: window, to: self)
    }

    private func forward(_ event: NSEvent, _ phase: ChromiumPageInput.Mouse.Phase, button: Int32) { // perf-hot: 5us cef-host-input (every mouse event)
        input?.send(ChromiumPageInput.mouse(event, in: self, phase: phase, button: button))
    }

    // MARK: Keys

    /// Keys cmux's key router left to the page (it runs first, in `CmuxApplication.sendEvent`).
    override func keyDown(with event: NSEvent) {
        guard input != nil else { return super.keyDown(with: event) }
        forwardKey(event)
    }

    override func keyUp(with event: NSEvent) {
        guard let input else { return super.keyUp(with: event) }
        input.send(ChromiumPageInput.key(event))
    }

    override func flagsChanged(with event: NSEvent) {
        guard let input else { return super.flagsChanged(with: event) }
        input.send(ChromiumPageInput.key(event))
    }

    /// A Command chord the key router left to the page goes to the page before the main menu, as Chrome's page view
    /// takes it (`-[RenderWidgetHostViewCocoa performKeyEquivalent:]`): AppKit offers key equivalents to every view of
    /// the window first, so only the first responder takes it. A chord the page leaves unhandled comes back through
    /// Chromium's unhandled-key hook, which gives it to the main menu (`CEFRuntime.routeUnhandledKey`). The app's
    /// reserved chords (``isReservedForApp(_:)``) go straight to the menu, as Chrome reserves its own.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard input != nil, event.type == .keyDown, let window, window.firstResponder === self,
              event.modifierFlags.contains(.command), !Self.isReservedForApp(event) else {
            return super.performKeyEquivalent(with: event)
        }
        forwardKey(event)
        return true
    }

    /// Command chords a page never gets first: Quit, Hide, Hide Others, Minimize and the window cycle (Cmd-`), which a
    /// page that cancels every key would otherwise keep from the app (Chrome's reserved commands, `IsReservedCommand`).
    nonisolated static func isReservedForApp(_ event: NSEvent) -> Bool {
        let chord = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard chord == .command || chord == [.command, .option] else { return false }
        switch event.keyCode {
        case 12: return chord == .command  // Q
        case 4: return true  // H, Option-H
        case 46: return chord == .command  // M
        case graveKeyCode: return true
        default: return false
        }
    }

    private func forwardKey(_ event: NSEvent) { // perf-hot: 5us cef-host-input (every key event)
        guard let input else { return }
        if event.type == .keyDown { input.willForwardKey(event) }
        input.send(ChromiumPageInput.key(event))
    }

    /// The `` ` `` key (kVK_ANSI_Grave).
    nonisolated static let graveKeyCode: UInt16 = 50

    // MARK: Edit menu

    @objc func copy(_ sender: Any?) { edit(.copy) }
    @objc func cut(_ sender: Any?) { edit(.cut) }
    @objc func paste(_ sender: Any?) { edit(.paste) }
    @objc override func selectAll(_ sender: Any?) { edit(.selectAll) }
    @objc func undo(_ sender: Any?) { edit(.undo) }
    @objc func redo(_ sender: Any?) { edit(.redo) }
    @objc func delete(_ sender: Any?) { edit(.delete) }
    /// Chrome's selector for Paste and Match Style (`ChromiumPasteAndMatchStyleRoute` sends it for Cmd-Shift-V).
    @objc func pasteAndMatchStyle(_ sender: Any?) { edit(.pasteAndMatchStyle) }

    private func edit(_ command: ChromiumPageInput.Edit) {
        input?.send(.edit(command))
    }

    // MARK: Cursor

    /// Without a layout screen's pointer area (a popup window's page) the cursor goes by this view's cursor rect.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard input != nil, !isServedByPanePointerArea else { return }
        addCursorRect(visibleRect, cursor: pageCursor ?? .arrow)
    }

    /// Chromium changed the cursor (its answer to a move comes after the move): it shows now while the pointer is over
    /// the page, and the next move's hit test shows it too (``panePointerCursor(at:)``, the cursor rect).
    func pageCursorChanged() {
        guard input != nil else { return }
        if !isServedByPanePointerArea { window?.invalidateCursorRects(for: self) }
        showPageCursor()
    }

    private func showPageCursor() {
        guard pointerInside, let window, window.isVisible else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(point) else { return }
        (pageCursor ?? .arrow).set()
    }
}

/// In a pane the layout screen's one tracking area hit-tests the pointer and calls these (always active, so a page in
/// a window that is not key gets its hover as Chrome's does), and sets the cursor this returns.
extension CEFHostedPageView: PanePointerFollowing {
    func panePointerCursor(at point: NSPoint) -> NSCursor? {
        guard input != nil else { return nil }
        return pageCursor ?? .arrow
    }

    func panePointerEntered(with event: NSEvent) {
        guard input != nil else { return }
        pointerInside = true
        forward(event, .move, button: 0)
    }

    func panePointerMoved(with event: NSEvent) {
        guard input != nil else { return }
        pointerInside = true
        forward(event, .move, button: 0)
    }

    func panePointerExited(with event: NSEvent) {
        guard input != nil else { return }
        pointerInside = false
        forward(event, .exit, button: 0)
    }
}
