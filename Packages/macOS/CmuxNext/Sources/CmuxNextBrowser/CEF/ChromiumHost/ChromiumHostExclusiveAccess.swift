import AppKit
import CmuxNextWakeups
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

/// A hosted page's HTML fullscreen, pointer lock and keyboard lock (task p01-process-229 of
/// plans/cmux-next/chrome-parity/p01-process.md), as Chrome's ExclusiveAccessManager keeps them for
/// a tab (chrome/browser/ui/exclusive_access/exclusive_access_manager.cc, with its
/// FullscreenController, PointerLockController and KeyboardLockController). The Chromium Host runs the
/// fork's lock delegate; cmux decides, locks its own cursor and keys and answers. No host window goes
/// fullscreen: the page's tab hides its toolbar and its pane zooms to fill the window
/// (``BrowserTabIntent/contentFullscreen(_:)``).
///
/// - Only the page that has the keyboard in the key window of the active app takes a lock
///   (``mayLock(_:)``), as Chrome locks only for the focused widget.
/// - Escape ends what is active at once, and the page does not get it
///   (`ExclusiveAccessManager::HandleUserKeyEvent`): the pointer lock, the fullscreen, and the keyboard
///   lock only while it holds keys. While a keyboard lock takes Escape the page gets it, and only
///   Escape held for ``holdEscape`` ends them (KeyboardLockController's press and hold, a one-shot
///   timer from the key down).
/// - A keyboard lock holds keys only while its page is in fullscreen, as Chrome activates it only in
///   tab fullscreen: a page cannot take cmux's shortcuts outside it, and a lock asked for before the
///   fullscreen stays pending, with Escape the page's (`HandleUserPressedEscape` answers false while
///   `!IsKeyboardLockActive()`).
/// - Leaving the keyboard ends the pointer lock (`RenderWidgetHostViewMac` loses it with the focus),
///   and so do the window resigning key and the app resigning active
///   (`RenderWidgetHostViewMac::SetActive(false)` unlocks the pointer); showing another page or leaving
///   the window ends everything.
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

    /// How long Escape is held to end a lock that takes Escape (`kHoldEscapeTime`, keyboard_lock_controller.cc).
    static let holdEscape: Duration = .milliseconds(1500)
    /// Escape's key code.
    static let escapeKeyCode: UInt16 = 53

    private(set) var pointerLock: PointerLock?
    private(set) var keyboardLock: KeyboardLock?
    /// The browser whose page is in HTML fullscreen (FULLSCREEN a = 1), nil while none.
    private(set) var fullscreen: Int32?
    /// The held Escape's deadline is armed (an Escape went down while a lock takes Escape).
    private(set) var isHoldingEscape = false
    /// The pointer lock holds the system cursor: hidden and dissociated (``ChromiumHostCursorLock/lock`` succeeded).
    private(set) var holdsCursor = false
    /// The cursor's lock: the system's in the app, a recorder in tests.
    var cursor: ChromiumHostCursorLock
    /// Where exits and locked moves go; nil leaves everything to the page.
    weak var wire: (any ChromiumHostExclusiveAccessWire)?
    /// The held Escape's deadline (``CEFHostLocks/serve(_:)`` sets it with ``wire``).
    var holdTimer: (any ChromiumHostHoldTimer)?
    /// The app's notices (`AppServices.appEvents`): its resign-active ends the pointer lock.
    var appEvents: AppEvents?
    /// The page view's window resigning key and the app resigning active, while a wire is set.
    private var focusWatch: [EventSubscription] = []

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
            if pointerLock == nil { holdsCursor = cursor.lock() }
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
            stopHoldingEscape()
            return true
        case .keyboardUnlocked:
            guard keyboardLock?.browser == browser else { return false }
            keyboardLock = nil
            stopHoldingEscape()
            return true
        }
    }

    /// The page of `browser` entered (`entering`) or left HTML fullscreen.
    func fullscreenChanged(_ entering: Bool, browser: Int32) {
        if entering {
            fullscreen = browser
        } else if fullscreen == browser {
            fullscreen = nil
            stopHoldingEscape()
        }
    }

    /// An Escape key down (`down`: a press or an auto-repeat, which never restarts the held deadline) or up of
    /// the page view. Returns true when it is taken here and the page never gets it. Only what is active
    /// takes it: a keyboard lock outside its page's fullscreen is pending, and Escape is the page's then.
    func escape(down: Bool) -> Bool {
        guard wire != nil, pointerLock != nil || fullscreen != nil else {
            stopHoldingEscape()
            return false
        }
        guard holdsKeys, keyboardLock?.escapeLocked == true else {
            guard down else { return false }
            exitActive(byUser: true)
            return true
        }
        // The lock takes Escape: the page gets every press, and the deadline armed on the key down
        // ends the locks unless the key comes up first.
        if !down {
            stopHoldingEscape()
        } else if !isHoldingEscape, let holdTimer {
            isHoldingEscape = true
            holdTimer.start(after: Self.holdEscape) { [weak self] in self?.heldEscapeFired() }
        }
        return false
    }

    /// Escape was held for ``holdEscape``.
    private func heldEscapeFired() {
        guard isHoldingEscape else { return }
        isHoldingEscape = false
        exitActive(byUser: true)
    }

    private func stopHoldingEscape() {
        guard isHoldingEscape else { return }
        isHoldingEscape = false
        holdTimer?.stop()
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

    /// The page view left the keyboard, its window resigned key or the app resigned active: the
    /// pointer lock ends (not by the person).
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
            stopHoldingEscape()
            wire?.exitKeyboardLock(keyboardLock.browser)
        }
        if let fullscreen, fullscreen != browser {
            self.fullscreen = nil
            stopHoldingEscape()
            wire?.exitFullscreen(fullscreen)
        }
    }

    /// Ends what is active, as Escape does: the pointer lock, the fullscreen, and the keyboard lock
    /// while it holds keys (a pending one stays). The fullscreen ends when the page says so
    /// (FULLSCREEN a = 0).
    func exitActive(byUser: Bool) {
        let (pointer, shown) = (pointerLock, fullscreen)
        let keyboard = holdsKeys ? keyboardLock : nil
        releasePointer()
        if keyboard != nil { keyboardLock = nil }
        stopHoldingEscape()
        if let pointer { wire?.exitPointerLock(pointer.browser, byUser: byUser) }
        if let keyboard { wire?.exitKeyboardLock(keyboard.browser) }
        if let shown { wire?.exitFullscreen(shown) }
    }

    /// Follows the page view's window (`windowEvents`, nil out of a window) and the app while a wire
    /// is set: the window resigning key or the app resigning active ends the pointer lock
    /// (``focusLost()``), as Chrome's `RenderWidgetHostViewMac::SetActive(false)` does, and the window
    /// leaving macOS fullscreen ends the page's HTML fullscreen (``windowLeftFullscreen()``). Called when
    /// the view changes window and when ``CEFHostLocks`` serves it.
    func follow(_ windowEvents: WindowEvents?) {
        for subscription in focusWatch { subscription.cancel() }
        focusWatch = []
        guard wire != nil, let windowEvents else { return }
        let owner = "ChromiumHostExclusiveAccess.focus"
        let lost: @MainActor () -> Void = { [weak self] in self?.focusLost() }
        focusWatch = [
            windowEvents.subscribe(NSWindow.didResignKeyNotification, owner: owner, lost),
            windowEvents.subscribe(NSWindow.didExitFullScreenNotification, owner: owner) { [weak self] in self?.windowLeftFullscreen() },
        ]
        if let appEvents { focusWatch.append(appEvents.subscribe(NSApplication.didResignActiveNotification, owner: owner, lost)) }
    }

    /// The page view's window left macOS fullscreen: the page's HTML fullscreen ends with it, as Chrome's
    /// tab fullscreen ends with its window's (`NativeWidgetNSWindowHost::OnWindowFullscreenTransitionComplete`,
    /// `FullscreenController::WindowFullscreenStateChanged`).
    func windowLeftFullscreen() {
        guard let fullscreen else { return }
        wire?.exitFullscreen(fullscreen)
    }

    /// An Escape down or up of the page view (`phase` as its key frame: 0 down, 1 up, 2 flags); true
    /// when it is taken here. Escape with a modifier is the page's.
    func takesEscape(_ event: NSEvent, phase: Int32) -> Bool {
        guard event.keyCode == Self.escapeKeyCode, phase != 2,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else { return false }
        return escape(down: phase == 0)
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
        stopHoldingEscape()
        (keyboardLock, fullscreen) = (nil, nil)
    }

    private func releasePointer() {
        guard pointerLock != nil else { return }
        pointerLock = nil
        holdsCursor = false
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

extension ChromiumHostPageView {
    /// The page view's window and the app, for its exclusive access (``ChromiumHostExclusiveAccess/follow(_:)``):
    /// the window's shared ``WindowEvents`` from ``visibilitySource``.
    func followWindowForExclusiveAccess() {
        exclusiveAccess.follow(window.map { visibilitySource.events($0) })
    }
}
