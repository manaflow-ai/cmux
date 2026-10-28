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
    /// A page the Chromium Host hosts detached (``hostDetachedPage(browser:)``) has no window that
    /// orders in: its focus is the fork's embedder-active state (API 30), the key state of a page
    /// with no key window, posted on the control channel. Chrome focuses a widget whose NSView
    /// lives in another process the same way: the browser sets the widget's focus and no window of
    /// its own becomes key (`RenderWidgetHostViewMac::SetActive`,
    /// content/browser/renderer_host/render_widget_host_view_mac.mm). Every other page (in
    /// process, or a host page not detached yet, whose page window is the only one that can take
    /// its keys) keeps CEF's `SetFocus`. With a view input target the pane's page view is also
    /// cmux's first responder, as Chrome's app shim view reports its first responder change
    /// (`RenderWidgetHostViewCocoa -becomeFirstResponder` to `OnFirstResponderChanged`,
    /// content/app_shim_remote_cocoa/render_widget_host_view_cocoa.mm).
    func applyFocus(_ focused: Bool, browser: Int32) {
        guard host.isHostMode, detachedBrowser == browser else {
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
    /// responder while this tab shows in it (``ChromiumHostPageView/onFocusChange``). Only a
    /// detached page's focus is embedder-active.
    func hostedPageFocusChanged(_ focused: Bool) {
        guard host.isHostMode, let browserID, detachedBrowser == browserID else { return }
        setEmbedderActive(focused, browser: browserID)
    }

    /// The Chromium Host now hosts `browser`'s page detached (fork API 30 `set_detached_hosting`,
    /// which the host turns on with the page's layer hosting; ``CEFPaneHost/showHostedContext(of:)``
    /// learns of it from the hosting reply): from here its focus is embedder-active, and focus
    /// asked for before it applies now.
    func hostDetachedPage(browser: Int32) {
        guard host.isHostMode, browserID == browser, detachedBrowser != browser else { return }
        detachedBrowser = browser
        embedderActive = nil
        if pendingFocus || focusWanted, host.visibleTab === self, !isContentHidden {
            pendingFocus = false
            applyFocus(true, browser: browser)
        }
    }

    /// Posts the page's embedder-active state when it differs from the one last posted for `browser`.
    private func setEmbedderActive(_ active: Bool, browser: Int32) {
        if let embedderActive, embedderActive.browser == browser, embedderActive.active == active { return }
        embedderActive = (browser, active)
        host.lifecycleTrace.record(id, "embedder-active(\(active))")
        _ = runtime.shim?.browserSetEmbedderActive(browser, active ? 1 : 0)
    }
}
