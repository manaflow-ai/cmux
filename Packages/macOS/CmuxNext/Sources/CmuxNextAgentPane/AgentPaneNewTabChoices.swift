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

    public init(kind: AgentPaneTabKind, text: String, cwd: String? = nil, search: Bool = false, run: Bool = true) {
        self.kind = kind
        self.text = text
        self.cwd = cwd
        self.search = search
        self.run = run
    }
}

/// A setting the new tab page writes: its "default: X" toggle or a template dot. The App checks the value.
public nonisolated enum AgentPaneNewTabSetting: Equatable, Sendable {
    case defaultKind(String)
    case template(String)
}

extension AgentPaneModel {
    /// Only while the tab is still the page.
    func write(_ setting: AgentPaneNewTabSetting, method: String) -> [String: Any] {
        guard newTab != nil, let onNewTabSetting else { return Self.unsupported(method) }
        onNewTabSetting(setting)
        return AgentPaneReply.success()
    }
}
