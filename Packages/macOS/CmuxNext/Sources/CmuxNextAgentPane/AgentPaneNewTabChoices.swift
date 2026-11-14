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

    public init(kind: AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true, keep: Bool = false,
                profile: AgentPaneOpenTabProfile? = nil, inPlace: Bool = false) {
        self.profile = profile
        self.inPlace = inPlace
        self.kind = kind
        self.text = text
        self.cwd = cwd
        self.search = search
        self.run = run
        self.keep = keep
    }
}
