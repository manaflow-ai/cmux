public import CmuxNextSettings

/// Whether a Chromium tab that committed a page moves to WebKit for its `browser.siteEngines` rule.
///
/// The resolver (`BrowserEngineResolver`) reads the rule only when a tab is made with a URL. A tab
/// that reaches the site later (a New Tab page where the address is typed, a link, a redirect, a
/// restored record) kept Chromium, and Spotify then showed "Playback of protected content is not
/// enabled" (https://github.com/manaflow-ai/cmux/issues/45018). Each committed page is checked
/// again here; the tab reopens in WebKit at that address, once, unless someone asked for its
/// engine or an agent drives it. Pure.
///
/// ```swift
/// let move = BrowserSiteEngineNavigation(siteEngine: rules.engine(for: url), engineIsChromium: true,
///                                        enginePinned: false, alreadyReopened: false, agentDriven: false)
/// if move.reopensInWebKit { ... }
/// ```
public nonisolated struct BrowserSiteEngineNavigation: Sendable, Equatable {
    /// The `browser.siteEngines` rule for the committed page, nil when none matches.
    public var siteEngine: BrowserDefaultEngine?
    /// The tab shows its page in Chromium (a WebKit tab never moves).
    public var engineIsChromium: Bool
    /// Someone asked for the tab's engine (`--engine chromium`, the other-browser modifier): their
    /// choice wins.
    public var enginePinned: Bool
    /// The tab reopened in WebKit once already (a site rule or a protected media refusal).
    public var alreadyReopened: Bool
    /// An agent drives the tab: moving it would take the page from under the agent.
    public var agentDriven: Bool

    public init(siteEngine: BrowserDefaultEngine?, engineIsChromium: Bool, enginePinned: Bool, alreadyReopened: Bool,
                agentDriven: Bool) {
        self.siteEngine = siteEngine
        self.engineIsChromium = engineIsChromium
        self.enginePinned = enginePinned
        self.alreadyReopened = alreadyReopened
        self.agentDriven = agentDriven
    }

    /// True when the tab reopens in WebKit at the committed address.
    public var reopensInWebKit: Bool {
        siteEngine == .webkit && engineIsChromium && !enginePinned && !alreadyReopened && !agentDriven
    }
}
