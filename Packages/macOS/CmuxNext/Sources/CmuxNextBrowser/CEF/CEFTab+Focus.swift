import Foundation

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
    func grantFocus(_ browser: Int32) {
        isGrantingFocus = true
        defer { isGrantingFocus = false }
        runtime.shim?.setFocus(browser, 1)
    }

    /// Runs `body` as if inside cmux's own `SetFocus(true)` (tests).
    func withFocusGrant<T>(_ body: () -> T) -> T {
        isGrantingFocus = true
        defer { isGrantingFocus = false }
        return body()
    }
}
