/// Which new tab design the page shows (Debug Settings `newTab.layout`):
/// `b` the Search | Ask screen, `a` the Terminal | Browser | Agent page,
/// kept until B passes dogfood (plans/cmux-next/new-tab.md, decision Q6).
public nonisolated enum AgentPaneNewTabLayout: String, CaseIterable, Codable, Sendable {
    case a, b
}

/// The screen's Search | Ask switch: what plain text does.
public nonisolated enum AgentPaneNewTabMode: String, CaseIterable, Codable, Sendable {
    case search, ask
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

    public init(kind: AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true) {
        self.kind = kind
        self.text = text
        self.cwd = cwd
        self.search = search
        self.run = run
    }
}
