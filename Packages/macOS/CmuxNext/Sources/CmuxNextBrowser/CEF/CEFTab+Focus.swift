import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// Where a Chromium focus request comes from (`cef_focus_source_t`).
nonisolated enum CEFFocusSource: Int32, Sendable {
    /// CEF focuses a page after it navigates it: the first load of a new
    /// browser (`ChromeBrowserHostImpl::Create`) and every `LoadURL`.
    case navigation = 0
    /// `CefBrowserHost::SetFocus(true)`, which cmux itself calls.
    case system = 1

    var name: String {
        switch self {
        case .navigation: "navigation"
        case .system: "system"
        }
    }
}

/// C entry for `CefFocusHandler::OnSetFocus` (main thread, CEF's UI
/// thread). Returns 1 when the page may take focus.
let cefFocusRequestCallback: CEFShimLibrary.FocusRequestFn = { context, browser, source in
    guard let context, Thread.isMainThread else { return 0 }
    let address = UInt(bitPattern: context)
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        CEFRuntime.from(address)?.focusRequested(browser: browser, source: source) == true ? 1 : 0
    }
}

extension CEFRuntime {
    /// Chromium asks to focus a page. Unknown browsers (a popup not adopted
    /// yet) are refused: only a tab cmux shows can be given focus.
    func focusRequested(browser: Int32, source: Int32) -> Bool {
        guard let tab = tabsByBrowser[browser] else { return false }
        return tab.chromiumRequestsFocus(CEFFocusSource(rawValue: source) ?? .system)
    }
}

/// The app's key window, read and changed (AppKit's in the app, a recorder in a test).
struct CEFKeyWindows {
    var keyWindow: @MainActor () -> NSWindow?
    var makeKey: @MainActor (NSWindow) -> Void

    static var appKit: CEFKeyWindows { CEFKeyWindows(keyWindow: { NSApp.keyWindow }, makeKey: { $0.makeKey() }) }
}

extension CEFTab {
    /// Chromium asks to focus this page (`CefFocusHandler::OnSetFocus`).
    ///
    /// Only cmux gives a page focus: the focus coordinator decides, and
    /// `setFocused(true)` asks inside `grantFocus`. CEF's own requests are
    /// refused. It asks after every navigation it starts, and on macOS
    /// granting one activates the page window, which takes the keys from
    /// the omnibar of a new tab (that omnibar stays focused until the
    /// user clicks the page) or from wherever the user is typing.
    func chromiumRequestsFocus(_ source: CEFFocusSource) -> Bool {
        if isGrantingFocus { return true }
        host.lifecycleTrace.record(id, "focus-refused source=\(source.name)")
        return false
    }

    /// Gives the page focus on cmux's behalf. CEF asks back through
    /// `chromiumRequestsFocus` inside this call (the shim's calls run on
    /// CEF's UI thread, the main thread).
    ///
    /// Chromium's model is one key window per browser window, which hands its keys to the focused page. Here the page
    /// is a child window that must itself be key, and CEF's SetFocus is the one call that makes it so. When it gives
    /// the page focus but moves no key (seen after an address-bar load in a fresh launch), the cmux window that shows
    /// the page keeps the keys with itself as first responder, and a typed key reaches no view: the page window takes
    /// them here, in the grant every path uses (a direct grant, one after the browser exists, one after the page
    /// shows), and from another page window of the same cmux window. Still one key change per request (#24913); never
    /// from another window or an inactive app.
    func grantFocus(_ browser: Int32) {
        // A page detached for a resize motion (fork API 30) has no window on screen: a grant now moves no keys, and
        // typed keys reach no view. It gets its window back first; the window is a child of this window again only
        // after the next commit, so the grant waits for that commit. Every grant path comes here.
        // A page shown in a recent turn waits for its first frame out of the window (`CEFLayerHosting.firstFrameHold`):
        // the ask is kept and the hold's end grants it, so nothing re-arms a grant each pass meanwhile.
        // A window still being restored (Restart to Update shows its windows one per frame) cannot hold the keys: a grant
        // now made the page window key before its cmux window showed, and the app lost its key window. The ask is kept
        // until the window comes on screen (`CEFRuntime.windowOcclusionChanged`), however many frames that takes. A count
        // of re-asks after frame commits ran back to back in one turn (each commit wakes the run loop) and dropped the
        // ask after the last.
        if let owner = container.window, !owner.showsOnScreen {
            host.lifecycleTrace.record(id, "grant kept: window not on screen")
            traceGrant("kept: window not on screen")
            pendingFocus = true
            runtime.asksAwaitingWindow[ObjectIdentifier(self)] = CEFAskAwaitingWindow(tab: self, window: owner)
            return
        }
        let hosting = host.hostView.layerHosting
        if hosting.holdsFirstFrame() {
            host.lifecycleTrace.record(id, "grant kept: first-frame hold")
            traceGrant("kept: first-frame hold")
            pendingFocus = true
            return
        }
        if hosting.pageTakesFocus() {
            host.lifecycleTrace.record(id, "grant kept: motion")
            traceGrant("kept: motion")
            pendingFocus = true
            AfterFrameCommit().run { [weak self] in self?.grantPendingFocusIfShown() }
            return
        }
        // A page with the focus and the keys from its last grant needs none: each SetFocus(true) dropped the keys typed
        // in the next 20 to 50 ms (Cmd-N's drain asked again for the page that had them; cmdn-typing bench, cmux21).
        if pageWindowHasTheKeys {
            traceGrant("skipped: has the keys")
            return host.lifecycleTrace.record(id, "grant skipped: has the focus and the keys")
        }
        isGrantingFocus = true
        defer { isGrantingFocus = false }
        runtime.shim?.setFocus(browser, 1)
        defer { keyedPageWindow = pageWindow.flatMap { keyWindows.keyWindow() === $0 ? $0 : nil } }
        // From the cmux window, or from another page window of it: Cmd-N typed in a page left that page's window key, and
        // the new page's held keys went to it, a page the switch hid (Lawrence 2026-11-19, "i did cmd n and started typing
        // and it didnt have focus").
        // `cmux app clicks`: a grant that left the page window without the keys says why (no window, not in a cmux
        // window, another window or app key).
        guard let window = pageWindow, let owner = window.parent, let key = keyWindows.keyWindow(), key !== window,
              key === owner || key.parent === owner else {
            let outcome = if pageWindow == nil {
                "granted: no page window"
            } else if pageWindow?.parent == nil {
                "granted: page window out of the window"
            } else if keyWindows.keyWindow() === pageWindow {
                "granted"
            } else if keyWindows.keyWindow() == nil {
                "granted: no key window"
            } else {
                "granted: another window is key"
            }
            traceGrant(outcome)
            return
        }
        keyWindows.makeKey(window)
        traceGrant("granted")
    }

    /// `cmux app clicks`: the grant's outcome, on the newest press in the page's cmux window.
    private func traceGrant(_ outcome: String) {
        guard let window = pageWindow?.parent ?? container.window else { return }
        WindowOverlayHost.existingHost(for: window)?.clickTrace.pageGrant(tab: "\(id)", outcome: outcome)
    }

    /// Whether this page has the focus of its last grant and its window still has the keys that grant gave it: no blur
    /// since, and that window is in the cmux window and key.
    var pageWindowHasTheKeys: Bool {
        guard let window = keyedPageWindow, window.parent != nil, window.parent === container.window else { return false }
        return keyWindows.keyWindow() === window
    }
}

/// A focus ask a page kept while its cmux window was not on screen (``CEFTab/grantFocus(_:)``) or another window had the
/// keys (``CEFTab/grantPendingFocusIfShown()``): the page, which owns the ask (``CEFTab/pendingFocus``), and the window
/// it waits for.
struct CEFAskAwaitingWindow {
    weak var tab: CEFTab?
    weak var window: NSWindow?
}

extension CEFRuntime {
    /// A window's occlusion changed (``windowGuard``, the app's one observer of it). The focus asks pages kept while
    /// this window was not on screen are granted once it is, after this pass's frame commit, each once: the grant clears
    /// the page's ask. Only the pages waiting for this window are told. A change that leaves it off screen tells none,
    /// and a grant that finds it off screen again (it came on screen and left before the commit) keeps the ask for the
    /// next change.
    func windowOcclusionChanged(_ window: NSWindow) {
        guard window.showsOnScreen else { return }
        grantAsks(waitingFor: window)
    }

    /// A window became key (``windowGuard``). A window switch reports the window on screen before it reports it key, so
    /// an ask re-asked when it came on screen found another window key and waited: it is granted now, as on screen. A
    /// grant that finds the window off screen (key before it was ordered in) waits for its occlusion change.
    func windowBecameKey(_ window: NSWindow) {
        grantAsks(waitingFor: window)
    }

    /// Grants, after this pass's frame commit, the asks that wait for `window`. Each is told once, then forgotten: a
    /// grant that still cannot run keeps its ask for the window's next change.
    private func grantAsks(waitingFor window: NSWindow) {
        for (page, ask) in asksAwaitingWindow where ask.window === window || ask.tab == nil {
            asksAwaitingWindow[page] = nil
            guard let tab = ask.tab else { continue }
            AfterFrameCommit().run { [weak tab] in tab?.grantPendingFocusIfShown() }
        }
    }
}

fileprivate extension NSWindow {
    /// Ordered in and not fully covered: a window that can hold the keys.
    var showsOnScreen: Bool { isVisible && occlusionState.contains(.visible) }
}
