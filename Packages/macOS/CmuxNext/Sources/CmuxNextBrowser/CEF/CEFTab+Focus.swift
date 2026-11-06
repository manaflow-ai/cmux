import AppKit
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
    /// shows). Still one key change per request (#24913); never from another window or an inactive app.
    func grantFocus(_ browser: Int32) {
        // A page detached for a resize motion (fork API 30) has no window on screen: a grant now moves no keys, and
        // typed keys reach no view. It gets its window back first; the window is a child of this window again only
        // after the next commit, so the grant waits for that commit. Every grant path comes here.
        if host.hostView.layerHosting.pageTakesFocus() {
            pendingFocus = true
            AfterFrameCommit().run { [weak self] in self?.grantPendingFocusIfShown() }
            return
        }
        isGrantingFocus = true
        defer { isGrantingFocus = false }
        runtime.shim?.setFocus(browser, 1)
        guard let window = pageWindow, let key = keyWindows.keyWindow(), key !== window, window.parent === key else { return }
        keyWindows.makeKey(window)
    }
}
