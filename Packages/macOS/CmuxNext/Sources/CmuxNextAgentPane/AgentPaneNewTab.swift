public import Foundation

/// The kinds the new tab page offers in its Terminal | Browser | Agent switch.
public nonisolated enum AgentPaneTabKind: String, CaseIterable, Codable, Sendable {
    case terminal, browser, agent
}

/// A tab opened as the new tab page (#16620): one field and a kind switch,
/// with recent sessions below, until the user picks what the tab becomes.
/// An agent choice stays in the page and starts the chat; a terminal or
/// browser choice asks the App to replace the tab (`tab.open`).
public nonisolated struct AgentPaneNewTab: Codable, Sendable, Equatable {
    /// The kind selected when the page opens: the kind of the tab it was
    /// opened from, so ⌘T keeps making what the user was using.
    public var kind: AgentPaneTabKind
    /// Each kind's New chord as the menus show it (`⇧⌘I`), keyed by
    /// ``AgentPaneTabKind/rawValue``; kinds without one are left out.
    public var hotkeys: [String: String]
    /// The folder a terminal or chat opened from the page starts in.
    public var cwd: String?

    public init(kind: AgentPaneTabKind, hotkeys: [AgentPaneTabKind: String] = [:], cwd: String? = nil) {
        self.kind = kind
        self.hotkeys = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        self.cwd = cwd
    }

    /// The `newTab` value of the handshake reply.
    var reply: [String: Any] {
        var value: [String: Any] = ["kind": kind.rawValue, "hotkeys": hotkeys]
        if let cwd { value["cwd"] = cwd }
        return value
    }
}
