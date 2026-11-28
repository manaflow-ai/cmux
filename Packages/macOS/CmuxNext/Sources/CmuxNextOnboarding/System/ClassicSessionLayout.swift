public import Foundation

/// A terminal or browser tab copied from a classic cmux session.
public nonisolated struct ClassicSessionTab: Codable, Equatable, Sendable {
    public let workingDirectory: String?
    /// The user's tab title, or a terminal's last title.
    public let title: String?
    /// A browser tab's page; nil for a terminal.
    public let url: String?
    /// The agent session the terminal ran, when classic recorded one.
    public let agent: ClassicSessionAgent?
    /// The terminal's saved scrollback text (with its colors); nil when
    /// classic saved none.
    public let scrollback: String?

    public init(workingDirectory: String?, title: String?, url: String? = nil, agent: ClassicSessionAgent? = nil,
                scrollback: String? = nil) {
        self.workingDirectory = workingDirectory
        self.title = title
        self.url = url
        self.agent = agent
        self.scrollback = scrollback
    }
}

/// A pane and its tabs, in the order shown by classic cmux.
public nonisolated struct ClassicSessionPane: Codable, Equatable, Sendable {
    public let tabs: [ClassicSessionTab]
    public let selectedTab: Int

    public init(tabs: [ClassicSessionTab], selectedTab: Int = 0) {
        self.tabs = tabs
        self.selectedTab = selectedTab
    }
}

/// The classic split tree. A pane is a leaf; a split preserves its axis and divider.
public nonisolated indirect enum ClassicSessionLayout: Codable, Equatable, Sendable {
    case pane(ClassicSessionPane)
    case split(orientation: Orientation, ratio: Double, first: ClassicSessionLayout, second: ClassicSessionLayout)

    public nonisolated enum Orientation: String, Codable, Sendable { case horizontal, vertical }

    /// The tree with only the tabs `keep` accepts; a side left with none
    /// closes up. Nil when no tab is kept.
    public func keeping(_ keep: (ClassicSessionTab) -> Bool) -> ClassicSessionLayout? {
        switch self {
        case .pane(let pane):
            let tabs = pane.tabs.filter(keep)
            guard !tabs.isEmpty else { return nil }
            let selected = pane.tabs.indices.contains(pane.selectedTab) ? pane.tabs[pane.selectedTab] : nil
            return .pane(ClassicSessionPane(tabs: tabs, selectedTab: selected.flatMap { tabs.firstIndex(of: $0) } ?? 0))
        case .split(let orientation, let ratio, let first, let second):
            switch (first.keeping(keep), second.keeping(keep)) {
            case (let a?, let b?): return .split(orientation: orientation, ratio: ratio, first: a, second: b)
            case (let a, let b): return a ?? b
            }
        }
    }

    /// The tree with each tab's folder, and its agent's, passed through `folder`.
    public func mappingFolders(_ folder: (String) -> String) -> ClassicSessionLayout {
        switch self {
        case .pane(let pane):
            return .pane(ClassicSessionPane(tabs: pane.tabs.map { tab in
                let agent = tab.agent.map {
                    ClassicSessionAgent(harness: $0.harness, sessionID: $0.sessionID, workingDirectory: $0.workingDirectory.map(folder))
                }
                return ClassicSessionTab(workingDirectory: tab.workingDirectory.map(folder), title: tab.title, url: tab.url, agent: agent,
                                         scrollback: tab.scrollback)
            }, selectedTab: pane.selectedTab))
        case .split(let orientation, let ratio, let first, let second):
            return .split(orientation: orientation, ratio: ratio,
                          first: first.mappingFolders(folder), second: second.mappingFolders(folder))
        }
    }

    /// Tabs in pane order, first side first.
    public var tabs: [ClassicSessionTab] {
        switch self {
        case .pane(let pane): pane.tabs
        case .split(_, _, let first, let second): first.tabs + second.tabs
        }
    }
}

