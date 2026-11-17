public import CmuxNextSettings

/// Whether a Chromium tab that committed a page moves to WebKit for its `browser.siteEngines` rule.
///
/// The resolver (`BrowserEngineResolver`) reads the rule only when a tab is made with a URL. A tab
/// that reaches the site later (an address typed on the New Tab page, a restored record) kept
/// Chromium, and Spotify then showed "Playback of protected content is not enabled"
/// (https://github.com/manaflow-ai/cmux/issues/45018). A committed page moves when the tab
/// arrived there fresh: its first web page, or one the person typed. A page reached from another
/// site in the same tab (a sign-in redirect through accounts.spotify.com) stays with that site's
/// cookies, and so does a page that keeps `window.opener`; the protected-media probe
/// (`BrowserProtectedMedia`) still moves them if playback is refused. Pure.
///
/// ```swift
/// let move = BrowserSiteEngineNavigation(siteEngine: rules.engine(for: url), engineIsChromium: true, arrivedFresh: true,
///                                        keepsOpener: false, enginePinned: false, alreadyReopened: false, agentDriven: false)
/// if move.reopensInWebKit { ... }
/// ```
public nonisolated struct BrowserSiteEngineNavigation: Sendable, Equatable {
    /// The `browser.siteEngines` rule for the committed page, nil when none matches.
    public var siteEngine: BrowserDefaultEngine?
    /// The tab shows its page in Chromium (a WebKit tab never moves).
    public var engineIsChromium: Bool
    /// The page is the tab's first web page (after the New Tab page, a blank page, a restore) or
    /// an address the person typed, not a page another site navigated to.
    public var arrivedFresh: Bool
    /// The page was made by its opener's engine and keeps `window.opener` (a popup adopted as a tab).
    public var keepsOpener: Bool
    /// Someone asked for the tab's engine (`--engine chromium`, the other-browser modifier): their
    /// choice wins.
    public var enginePinned: Bool
    /// The tab reopened in WebKit once already (a site rule or a protected media refusal).
    public var alreadyReopened: Bool
    /// An agent drives the tab: moving it would take the page from under the agent.
    public var agentDriven: Bool

    public init(siteEngine: BrowserDefaultEngine?, engineIsChromium: Bool, arrivedFresh: Bool, keepsOpener: Bool,
                enginePinned: Bool, alreadyReopened: Bool, agentDriven: Bool) {
        self.siteEngine = siteEngine
        self.engineIsChromium = engineIsChromium
        self.arrivedFresh = arrivedFresh
        self.keepsOpener = keepsOpener
        self.enginePinned = enginePinned
        self.alreadyReopened = alreadyReopened
        self.agentDriven = agentDriven
    }

    /// True when the tab reopens in WebKit at the committed address.
    public var reopensInWebKit: Bool {
        siteEngine == .webkit && engineIsChromium && arrivedFresh && !keepsOpener && !enginePinned && !alreadyReopened
            && !agentDriven
    }
}
