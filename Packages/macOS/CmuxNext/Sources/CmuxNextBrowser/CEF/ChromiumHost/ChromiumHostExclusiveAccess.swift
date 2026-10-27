import AppKit
import CoreGraphics

/// What a page view's exclusive access asks of the page's browser: the shim's lock calls and the
/// tab's fullscreen exit (``CEFHostLocks``), a recorder in tests.
@MainActor
protocol ChromiumHostExclusiveAccessWire: AnyObject {
    /// `cmux_shim_browser_exit_pointer_lock`: `byUser` starts Chrome's cooldown for the page.
    func exitPointerLock(_ browser: Int32, byUser: Bool)
    /// `cmux_shim_browser_exit_keyboard_lock`.
    func exitKeyboardLock(_ browser: Int32)
    /// Ends the page's HTML fullscreen (`document.exitFullscreen()`).
    func exitFullscreen(_ browser: Int32)
    /// `cmux_shim_browser_send_locked_mouse_move`: movement in DIP, `cef_event_flags_t` modifiers.
    func sendLockedMove(_ browser: Int32, dx: Double, dy: Double, modifiers: Int32)
}

/// Hides the cursor and holds it where it is while a page holds the pointer lock, as
/// `-[RenderWidgetHostViewCocoa setCursorLocked:]` does
/// (content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm):
/// `CGAssociateMouseAndMouseCursorPosition(NO)` and `[NSCursor hide]`, undone in the other order.
/// Tests pass a recorder.
struct ChromiumHostCursorLock {
    let lock: @MainActor () -> Void
    let unlock: @MainActor () -> Void

    @MainActor static let system = ChromiumHostCursorLock(
        lock: {
            NSCursor.hide()
            _ = CGAssociateMouseAndMouseCursorPosition(0)
        },
        unlock: {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        })
}

/// A hosted page's HTML fullscreen, pointer lock and keyboard lock (task p01-process-229 of
/// plans/cmux-next/chrome-parity/p01-process.md), as Chrome's ExclusiveAccessManager keeps them for
/// a tab (chrome/browser/ui/exclusive_access/exclusive_access_manager.cc, with its
/// FullscreenController, PointerLockController and KeyboardLockController). The Chromium Host runs the
/// fork's lock delegate; cmux decides, locks its own cursor and keys and answers. Fullscreen stays in
/// the page's pane, as WebKit's `PaneFullscreenScript` keeps it: the toolbar hides and the page view
/// fills the pane, and no host window goes fullscreen.
///
/// - Only the page that has the keyboard in the key window of the active app takes a lock
///   (``mayLock(_:)``), as Chrome locks only for the focused widget.
/// - Escape ends both locks and the fullscreen at once, and the page does not get it
///   (`ExclusiveAccessManager::HandleUserKeyEvent`). While a keyboard lock takes Escape the page gets
///   it, and only Escape held for ``holdEscape`` ends them (KeyboardLockController's press and hold).
/// - A keyboard lock holds keys only while its page is in fullscreen, as Chrome activates it only in
///   tab fullscreen: a page cannot take cmux's shortcuts outside it.
/// - Leaving the keyboard ends the pointer lock (`RenderWidgetHostViewMac` loses it with the focus);
///   showing another page or leaving the window ends everything.
///
/// Nothing here runs without ``wire`` (feature `chromiumHostLocks` off): no request is granted and
/// Escape stays the page's.
@MainActor
final class ChromiumHostExclusiveAccess {
    struct PointerLock: Equatable {
        let browser: Int32
        /// The page asked for unadjusted movement: locked moves carry the mouse's own deltas.
        let unadjustedMovement: Bool
    }

    struct KeyboardLock: Equatable {
        let browser: Int32
        let escapeLocked: Bool
    }

    /// How long Escape is held to end a lock that takes Escape (Chrome's keyboard_lock_controller.cc).
    static let holdEscape: TimeInterval = 1.5
    /// Escape's key code.
    static let escapeKeyCode: UInt16 = 53

    private(set) var pointerLock: PointerLock?
    private(set) var keyboardLock: KeyboardLock?
    /// The browser whose page is in HTML fullscreen (FULLSCREEN a = 1), nil while none.
    private(set) var fullscreen: Int32?
    /// When the Escape held now went down, while a lock takes Escape.
    private var escapeHeldSince: TimeInterval?
    let cursor: ChromiumHostCursorLock
    /// Where exits and locked moves go; nil leaves everything to the page.
    weak var wire: (any ChromiumHostExclusiveAccessWire)?

    init(cursor: ChromiumHostCursorLock) {
        self.cursor = cursor
    }

    /// Whether the page has any of the three.
    var isActive: Bool { pointerLock != nil || keyboardLock != nil || fullscreen != nil }

    /// A keyboard lock holds keys now: its page is in fullscreen. The key router then gives the page
    /// the chords cmux keeps from it (`KeyRouter.keyboardLockKeeps`).
    var holdsKeys: Bool {
        guard wire != nil, let keyboardLock else { return false }
        return fullscreen == keyboardLock.browser
    }

    /// A call of the fork's lock delegate for `browser`. Returns the answer of a request: true when
    /// cmux took the lock (`mayLock`: the page has the keyboard). An unlock of a lock this view does
    /// not hold changes nothing.
    @discardableResult
    func handle(_ event: ChromiumHostLockEvent, browser: Int32, detail: Int32, mayLock: Bool) -> Bool {
        switch event {
        case .pointerLockRequested:
            guard wire != nil, mayLock else { return false }
            if let held = pointerLock, held.browser != browser { wire?.exitPointerLock(held.browser, byUser: false) }
            if pointerLock == nil { cursor.lock() }
            pointerLock = PointerLock(browser: browser, unadjustedMovement: detail != 0)
            return true
        case .pointerUnlocked:
            guard pointerLock?.browser == browser else { return false }
            releasePointer()
            return true
        case .keyboardLockRequested:
            guard wire != nil, mayLock else { return false }
            if let held = keyboardLock, held.browser != browser { wire?.exitKeyboardLock(held.browser) }
            keyboardLock = KeyboardLock(browser: browser, escapeLocked: detail != 0)
            escapeHeldSince = nil
            return true
        case .keyboardUnlocked:
            guard keyboardLock?.browser == browser else { return false }
            keyboardLock = nil
            escapeHeldSince = nil
            return true
        }
    }

    /// The page of `browser` entered (`entering`) or left HTML fullscreen.
    func fullscreenChanged(_ entering: Bool, browser: Int32) {
        if entering {
            fullscreen = browser
        } else if fullscreen == browser {
            fullscreen = nil
            escapeHeldSince = nil
        }
    }

    /// An Escape key down (`down`) or up of the page view. Returns true when it is taken here and
    /// the page never gets it.
    func escape(down: Bool, isRepeat: Bool, at time: TimeInterval) -> Bool {
        guard wire != nil, isActive else {
            escapeHeldSince = nil
            return false
        }
        guard holdsKeys, keyboardLock?.escapeLocked == true else {
            guard down else { return false }
            exitAll(byUser: true)
            return true
        }
        guard down else {
            escapeHeldSince = nil
            return false
        }
        guard isRepeat, let since = escapeHeldSince else {
            escapeHeldSince = time
            return false
        }
        guard time - since >= Self.holdEscape else { return false }
        exitAll(byUser: true)
        return true
    }

    /// A mouse move or drag of the page view while the pointer is locked: its movement goes to the
    /// page as raw movement (`event`'s deltas, or the mouse's own when the page asked for unadjusted
    /// movement). Returns false while no pointer lock is held: the move is a pointer move then.
    func lockedMove(_ event: NSEvent) -> Bool {
        guard let pointerLock else { return false }
        let movement = Self.movement(of: event, unadjusted: pointerLock.unadjustedMovement)
        let modifiers = ChromiumHostDragDestination.modifiers(event.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons)
        wire?.sendLockedMove(pointerLock.browser, dx: movement.dx, dy: movement.dy, modifiers: modifiers)
        return true
    }

    /// The page view left the keyboard: the pointer lock ends (not by the person).
    func focusLost() {
        guard let pointerLock else { return }
        releasePointer()
        wire?.exitPointerLock(pointerLock.browser, byUser: false)
    }

    /// The page view shows `browser` (nil: no page, or it left its window): what another page held ends.
    func showing(_ browser: Int32?) {
        if let pointerLock, pointerLock.browser != browser {
            releasePointer()
            wire?.exitPointerLock(pointerLock.browser, byUser: false)
        }
        if let keyboardLock, keyboardLock.browser != browser {
            self.keyboardLock = nil
            escapeHeldSince = nil
            wire?.exitKeyboardLock(keyboardLock.browser)
        }
        if let fullscreen, fullscreen != browser {
            self.fullscreen = nil
            wire?.exitFullscreen(fullscreen)
        }
    }

    /// Ends both locks and the fullscreen, as Escape does. The fullscreen ends when the page says so
    /// (FULLSCREEN a = 0).
    func exitAll(byUser: Bool) {
        let (pointer, keyboard, shown) = (pointerLock, keyboardLock, fullscreen)
        releasePointer()
        keyboardLock = nil
        escapeHeldSince = nil
        if let pointer { wire?.exitPointerLock(pointer.browser, byUser: byUser) }
        if let keyboard { wire?.exitKeyboardLock(keyboard.browser) }
        if let shown { wire?.exitFullscreen(shown) }
    }

    /// An Escape down or up of the page view (`phase` as its key frame: 0 down, 1 up, 2 flags); true
    /// when it is taken here. Escape with a modifier is the page's.
    func takesEscape(_ event: NSEvent, phase: Int32) -> Bool {
        guard event.keyCode == Self.escapeKeyCode, phase != 2,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else { return false }
        return escape(down: phase == 0, isRepeat: event.isARepeat, at: event.timestamp)
    }

    /// A mouse event of the page view (`phase` 0 a move or drag): while the pointer is locked a move
    /// goes as raw movement; true when it went.
    func takesMove(_ event: NSEvent, phase: Int32) -> Bool {
        phase == 0 && lockedMove(event)
    }

    /// Whether a lock request of the page `page` shows may be granted: the view takes input, has the
    /// keyboard, and its window is the key window of the active app (Chrome grants a lock only to the
    /// focused widget of the active window, `RenderWidgetHostImpl::RequestPointerLock`).
    static func mayLock(_ page: ChromiumHostPageView) -> Bool {
        guard page.inputTarget == .view, let window = page.window, window.firstResponder === page else { return false }
        return window.isKeyWindow && NSApp.isActive
    }

    /// The Chromium Host ended: its pages and their locks went with it, so everything ends here with
    /// nothing sent, and the cursor is free again.
    func hostEnded() {
        releasePointer()
        (keyboardLock, fullscreen, escapeHeldSince) = (nil, nil, nil)
    }

    private func releasePointer() {
        guard pointerLock != nil else { return }
        pointerLock = nil
        cursor.unlock()
    }

    /// The locked movement of `event` in DIP. Unadjusted: the mouse's own deltas, which macOS keeps in
    /// the event's unaccelerated pointer movement fields (170 and 171), as Chrome reads them for
    /// `requestPointerLock({unadjustedMovement: true})` (WebMouseEventBuilder::Build,
    /// content/browser/renderer_host/input/web_input_event_builders_mac.mm).
    static func movement(of event: NSEvent, unadjusted: Bool) -> (dx: Double, dy: Double) {
        if unadjusted, let cgEvent = event.cgEvent, let x = CGEventField(rawValue: 170), let y = CGEventField(rawValue: 171) {
            return (cgEvent.getDoubleValueField(x), cgEvent.getDoubleValueField(y))
        }
        return (Double(event.deltaX), Double(event.deltaY))
    }
}
