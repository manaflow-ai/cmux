import AppKit

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
    // SAFETY: only the context's address is read; CEFRuntime.from turns it back into the runtime.
    let address = unsafe UInt(bitPattern: context)
    guard address != 0, Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated { // main-proof: guarded by Thread.isMainThread in the guard above
        CEFRuntime.from(address)?.focusRequested(browser: browser, source: source) == true ? 1 : 0
    }
}

extension CEFRuntime {
    /// Installs cmux's answer to Chromium's own focus requests, before `initialize`.
    ///
    /// In process cmux refuses them (``CEFTab/chromiumRequestsFocus(_:)``). In host mode cmux
    /// installs none: a synchronous answer would cross the wire. The host's shim grants a request
    /// only for a page cmux marked embedder-active, one its window's first responder shows
    /// (``CEFTab/applyFocus(_:browser:)``; CEFShim/src/embedder_focus_policy.h): a navigation in a
    /// background pane takes no focus, and the focused pane's page keeps it after its own load,
    /// as Chrome focuses only a window's active tab.
    func installFocusRequestPolicy(_ shim: CEFShimLibrary) {
        guard hostStart == nil else { return }
        // SAFETY: the handler is a C function of `cmux_shim_focus_request_fn`; its context is the runtime
        // `initialize` is given, which lives for the process once started.
        unsafe shim.setFocusRequestHandler(cefFocusRequestCallback)
    }

    /// Chromium asks to focus a page (in process only). Unknown browsers (a popup not adopted
    /// yet) are refused: only a tab cmux shows can be given focus.
    func focusRequested(browser: Int32, source: Int32) -> Bool {
        guard let tab = tabsByBrowser[browser] else { return false }
        return tab.chromiumRequestsFocus(CEFFocusSource(rawValue: source) ?? .system)
    }
}

extension CEFTab {
    /// Chromium asks to focus this page (`CefFocusHandler::OnSetFocus`), in process only
    /// (``CEFRuntime/installFocusRequestPolicy(_:)``).
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
}

extension CEFTab {
    /// Gives (`focused`) or takes the page's focus on cmux's behalf, the backend's way.
    ///
    /// In process: CEF's `SetFocus`, which makes the page window key. In host mode the page window
    /// is the Chromium Host's and must never be key (that activates the host, which has cmux's
    /// bundle id): focus is the pane's page view as cmux's own first responder plus the fork's
    /// embedder-active state (API 30), a post on the control channel, in order with the page's
    /// other ops. Chrome splits a page's focus the same way: the app shim's view reports its first
    /// responder change (`RenderWidgetHostViewCocoa -becomeFirstResponder` to
    /// `OnFirstResponderChanged`, content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm)
    /// and the browser focuses the widget with no window of its own becoming key.
    func applyFocus(_ focused: Bool, browser: Int32) {
        guard host.isHostMode else {
            if focused { grantFocus(browser) } else { runtime.shim?.setFocus(browser, 0) }
            return
        }
        if focused, let page = host.hostedPageView, page.acceptsFirstResponder, let window = page.window,
           window.firstResponder !== page {
            window.makeFirstResponder(page)
        }
        setEmbedderActive(focused, browser: browser)
    }

    /// Host mode: the pane's page view became (`true`) or stopped being its window's first
    /// responder while this tab shows in it (``ChromiumHostPageView/onFocusChange``).
    func hostedPageFocusChanged(_ focused: Bool) {
        guard host.isHostMode, let browserID else { return }
        setEmbedderActive(focused, browser: browserID)
    }

    /// Posts the page's embedder-active state when it differs from the one last posted for `browser`.
    private func setEmbedderActive(_ active: Bool, browser: Int32) {
        if let embedderActive, embedderActive.browser == browser, embedderActive.active == active { return }
        embedderActive = (browser, active)
        host.lifecycleTrace.record(id, "embedder-active(\(active))")
        _ = runtime.shim?.browserSetEmbedderActive(browser, active ? 1 : 0)
    }
}
