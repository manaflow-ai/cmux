import AppKit
import CmuxNextCompat
import CmuxNextWakeups

/// C entry for the fork's lock delegate (`cmux_shim_set_lock_handler`), its seam
/// adapter: the in-process shim calls it on the CEF UI thread and the remote shim from its event batch, both
/// the main thread; off it, the call hops there.
enum CEFHostLockCallback {
    static let handler: CEFShimLockOps.Handler = { context, event, browser, detail in
        // SAFETY: only the context's address is read; CEFRuntime.from turns it back into the runtime.
        let address = unsafe UInt(bitPattern: context)
        guard address != 0 else { return }
        guard Thread.isMainThread else {
            return MainRunLoopBlock.perform { CEFRuntime.from(address)?.hostStart?.locks?.received(event, browser: browser, detail: detail) }
        }
        MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread above
            CEFRuntime.from(address)?.hostStart?.locks?.received(event, browser: browser, detail: detail)
        }
    }
}

/// Host mode's pointer lock and keyboard lock (feature `chromiumHostLocks`, task p01-process-229 of
/// plans/cmux-next/chrome-parity/p01-process.md). The fork's lock delegate runs in the Chromium Host,
/// which pushes each of its calls (ChromiumHost/src/host_locks.h); the remote shim hands them to the
/// runtime's lock fn, and each goes to the page view that shows the tab it names, whose
/// ``ChromiumHostExclusiveAccess`` locks cmux's cursor or keys. This answers the request and is the
/// page views' way back to the page: exits, locked moves and the fullscreen exit. Chrome's app shim
/// does the same for a page whose browser process is elsewhere (RenderWidgetHostNSView's
/// SetCursorLocked and LockKeyboard, content/common/render_widget_host_ns_view.mojom).
final class CEFHostLocks: ChromiumHostExclusiveAccessWire {
    /// Fork API 31 has the lock delegate (task 227).
    static let forkAPI: Int32 = 31

    private weak var runtime: CEFRuntime?
    /// The app's notices (`AppServices.appEvents`): a page view's pointer lock ends when the app resigns active.
    private let appEvents: AppEvents?
    /// The page that holds the pointer lock: its unlock reaches it when its tab is gone (the host ended).
    private weak var pointerHolder: ChromiumHostExclusiveAccess?
    /// The lock fn is in the shim (the source asked for it and the fork took it).
    private(set) var isInstalled = false
    /// Requests answered so far, and of them those granted (`debug.cef` `host_locks`).
    private(set) var asked = 0
    private(set) var granted = 0

    init(runtime: CEFRuntime, appEvents: AppEvents?) {
        self.runtime = runtime
        self.appEvents = appEvents
    }

    /// Host mode, at the start (before `cmux_shim_initialize`; the remote shim sends it to every later
    /// host): puts the lock fn in the shim when the host's fork has the delegate. `forkAPIVersion` is
    /// the host's fork's; `context` is the runtime's callback token.
    func install(_ shim: CEFShimLibrary, forkAPIVersion: Int32, context: UnsafeMutableRawPointer?) {
        guard forkAPIVersion >= Self.forkAPI else { return }
        // SAFETY: a C function of `cmux_shim_set_lock_handler`'s fn type; its context is the runtime's token.
        isInstalled = unsafe shim.locks.setHandler(CEFHostLockCallback.handler, context) == 1
    }

    /// Host mode: `page` (a pane's page view) locks for its pages. Its held Escape runs on the runtime's
    /// deadline queue, and its window's resign-key and the app's resign-active end its pointer lock.
    func serve(_ page: ChromiumHostPageView) {
        let access = page.exclusiveAccess
        access.wire = self
        if let runtime { access.holdTimer = ChromiumHostWakeUpHoldTimer(deadlines: runtime.waitDeadlines) }
        access.appEvents = appEvents
        page.followWindowForExclusiveAccess()
    }

    /// One call of the fork's delegate. A request is answered at once: granted only for the page
    /// view that shows the tab and has the keyboard.
    func received(_ raw: Int32, browser: Int32, detail: Int32) {
        guard let event = ChromiumHostLockEvent(rawValue: raw) else { return }
        let page = shownPage(of: browser)
        switch event {
        case .pointerLockRequested:
            let granted = page.map { $0.exclusiveAccess.handle(event, browser: browser, detail: detail, mayLock: ChromiumHostExclusiveAccess.mayLock($0)) } ?? false
            if granted { pointerHolder = page?.exclusiveAccess }
            answered(granted)
            _ = runtime?.shim?.locks.pointerLockAnswer(browser, granted ? 1 : 0)
        case .keyboardLockRequested:
            let granted = page.map { $0.exclusiveAccess.handle(event, browser: browser, detail: detail, mayLock: ChromiumHostExclusiveAccess.mayLock($0)) } ?? false
            answered(granted)
            _ = runtime?.shim?.locks.keyboardLockAnswer(browser, granted ? 1 : 0)
        case .pointerUnlocked:
            (page?.exclusiveAccess ?? pointerHolder)?.handle(event, browser: browser, detail: detail, mayLock: false)
        case .keyboardUnlocked:
            page?.exclusiveAccess.handle(event, browser: browser, detail: detail, mayLock: false)
        }
    }

    private func answered(_ granted: Bool) {
        asked += 1
        if granted { self.granted += 1 }
    }

    /// The page view that shows `browser`'s tab now; nil for a hidden tab or a browser cmux has no tab of.
    private func shownPage(of browser: Int32) -> ChromiumHostPageView? {
        guard let tab = runtime?.tabsByBrowser[browser], tab.host.visibleTab === tab else { return nil }
        return tab.host.hostedPageView
    }

    // MARK: ChromiumHostExclusiveAccessWire

    func exitPointerLock(_ browser: Int32, byUser: Bool) {
        _ = runtime?.shim?.locks.exitPointerLock(browser, byUser ? 1 : 0)
    }

    func exitKeyboardLock(_ browser: Int32) {
        _ = runtime?.shim?.locks.exitKeyboardLock(browser)
    }

    func exitFullscreen(_ browser: Int32) {
        runtime?.tabsByBrowser[browser]?.exitContentFullscreen()
    }

    func sendLockedMove(_ browser: Int32, dx: Double, dy: Double, modifiers: Int32) {
        _ = runtime?.shim?.locks.sendLockedMouseMove(browser, dx, dy, modifiers)
    }
}

/// `debug.cef` `host_locks` (chromium-host-bench.py's fullscreen and lock rows): the lock requests
/// cmux answered and what the focused page view holds now.
public struct CEFHostLocksReport: Equatable, Sendable {
    public let installed: Bool
    public let asked: Int
    public let granted: Int
    /// The browser holding the pointer lock in the page view the person uses, nil while none; and
    /// whether it asked for unadjusted movement.
    public let pointer: Int32?
    public let unadjustedMovement: Bool
    /// The pointer lock holds the system cursor: hidden and dissociated from the mouse, so it stays in the page.
    public let cursorHeld: Bool
    public let keyboard: Int32?
    /// The keyboard lock holds cmux's keys now (its page is in fullscreen).
    public let holdsKeys: Bool
    public let fullscreen: Int32?
}

extension CEFEngine {
    /// The host's page locks; nil when cmux does not handle them (in process, or feature `chromiumHostLocks` off).
    /// `page` is the page view the person uses (the key window's first responder), nil for none.
    public func hostLocks(page: ChromiumHostPageView?) -> CEFHostLocksReport? {
        guard let locks = CEFRuntime.shared.hostStart?.locks else { return nil }
        let access = page?.exclusiveAccess
        return CEFHostLocksReport(installed: locks.isInstalled, asked: locks.asked, granted: locks.granted,
                                  pointer: access?.pointerLock?.browser, unadjustedMovement: access?.pointerLock?.unadjustedMovement ?? false,
                                  cursorHeld: access?.holdsCursor ?? false, keyboard: access?.keyboardLock?.browser, holdsKeys: access?.holdsKeys ?? false,
                                  fullscreen: access?.fullscreen)
    }
}
