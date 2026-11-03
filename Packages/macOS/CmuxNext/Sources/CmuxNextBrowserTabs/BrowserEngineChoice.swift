public import CmuxNextBrowser
public import CmuxNextDaemon

/// The engine a new browser tab gets, and why.
public nonisolated struct BrowserEngineChoice: Equatable, Sendable {
    /// The engine the tab opens in.
    public var engine: CmuxNextDaemon.BrowserEngine
    /// Set when the default engine (Chromium) could not be used and the tab
    /// opens in WebKit instead. Reported once (`ChromiumFallbackLog`).
    public var fallback: CEFUnavailableReason?
    /// The engine came from an existing record or page (reopen, duplicate,
    /// popup), not from the default.
    public var inherited = false
    /// Someone asked for this engine (`--engine`, the other-browser modifier, a
    /// `browser.siteEngines` rule): a refused protected-media request does not
    /// move the tab to the other engine (`BrowserProtectedMedia`).
    public var pinned = false

    /// What the tab loads when the user gave no URL: Chromium's New Tab
    /// page (new-tab extensions replace it), WebKit's blank page.
    public var newTabURL: String {
        BrowserNewTabPage.initialURL(for: engine == .cef ? .cef : .webkit)
    }

    /// A choice of `engine`.
    /// - Parameters:
    ///   - engine: the engine the tab opens in.
    ///   - fallback: why Chromium could not be used, when the tab falls back to WebKit.
    ///   - inherited: the engine came from an existing record or page.
    ///   - pinned: someone asked for this engine.
    public init(engine: CmuxNextDaemon.BrowserEngine, fallback: CEFUnavailableReason? = nil, inherited: Bool = false, pinned: Bool = false) {
        self.engine = engine
        self.fallback = fallback
        self.inherited = inherited
        self.pinned = pinned
    }
}
