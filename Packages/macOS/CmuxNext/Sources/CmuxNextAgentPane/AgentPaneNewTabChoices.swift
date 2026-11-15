/// Which new tab design the page shows (Debug Settings `newTab.layout`):
/// `b` the Search | Ask screen, `a` the Terminal | Browser | Agent page,
/// kept until B passes dogfood (plans/cmux-next/new-tab.md, decision Q6).
public nonisolated enum AgentPaneNewTabLayout: String, CaseIterable, Codable, Sendable {
    case a, b
}

/// What the page asks the App to replace it with (`tab.open`).
public nonisolated struct AgentPaneOpenTab: Equatable, Sendable {
    public var kind: AgentPaneTabKind
    public var text: String
    /// A terminal's folder when the page picked one.
    public var cwd: String?
    /// Browser: search `text` with the search engine even when it reads as an address.
    public var search: Bool
    /// Terminal: run `text` (variant A's Enter) or only type it at the prompt (`!`).
    public var run: Bool
    /// The page stays open beside the new tab (the Harnesses page's Sign In and Install…).
    public var keep: Bool
    /// Browser: the profile the page's Open in Profile… or Open in New Profile row named; nil opens
    /// in the profile a new tab of the workspace gets.
    public var profile: AgentPaneOpenTabProfile?
    /// The page's New terminal and New browser tab buttons: the new tab takes the page's place in its
    /// pane, never the pane on the right or a new split (`newTab.picksFollowLinks` is for picks).
    public var inPlace: Bool
    /// Browser: the person asked for a new tab (Option-Return or a modified row click, as in Chrome's
    /// omnibox), so the address opens where links go and the page stays. Without it a browser pick is a
    /// navigation: it takes the page's tab (``navigatesInPlace``).
    public var beside: Bool

    public init(kind: AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true, keep: Bool = false,
                profile: AgentPaneOpenTabProfile? = nil, inPlace: Bool = false, beside: Bool = false) {
        self.profile = profile
        self.inPlace = inPlace
        self.beside = beside
        self.kind = kind
        self.text = text
        self.cwd = cwd
        self.search = search
        self.run = run
        self.keep = keep
    }

    /// Whether this open navigates the page's own tab: a browser pick (a typed address, a web search, a
    /// visited page, a profile pick) that asked for no new tab, as Return in a browser's new tab loads there
    /// (Lawrence 2026-11-11: "we should instead just open it as replacement of current page, so a
    /// navigation"). `newTab.picksFollowLinks` still sends terminals and chats where links go.
    public var navigatesInPlace: Bool { kind == .browser && !beside && !keep }
}
