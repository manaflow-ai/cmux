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
    /// The tab the page opened from, as the location bar shows it (its URL or
    /// folder): in the field and selected, so typing replaces it.
    public var location: String?
    /// What the location bar suggests besides the typed text.
    public var omnibar: AgentPaneOmnibar
    /// Recent local project folders from agent history, classic sessions and git roots.
    public var projects: [String]
    /// What Cmd-T opens (`tabs.newTabKind`: "same-kind", "terminal",
    /// "browser", "agent", "page" or "auto"), for the "default: X" toggle.
    public var defaultKind: String?

    public init(kind: AgentPaneTabKind, hotkeys: [AgentPaneTabKind: String] = [:], cwd: String? = nil,
                location: String? = nil, omnibar: AgentPaneOmnibar = AgentPaneOmnibar(), projects: [String] = [],
                defaultKind: String? = nil) {
        self.kind = kind
        self.hotkeys = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        self.cwd = cwd
        self.location = location
        self.omnibar = omnibar
        // Keep the host DTO lossless. The web page owns presentation limits and
        // validation after the Codable handshake crosses the bridge.
        self.projects = projects
        self.defaultKind = defaultKind
    }
}

/// The location bar's suggestions from the app (#16651 follow-up): open tabs and
/// workspaces to jump to, folders to open a terminal in, recent commands and pages.
/// The page validates and caps each list before ranking it.
public nonisolated struct AgentPaneOmnibar: Codable, Sendable, Equatable {
    public struct Tab: Codable, Sendable, Equatable {
        public var id: String
        public var kind: AgentPaneTabKind
        public var title: String
        public var detail: String?
        public var workspace: String?

        public init(id: String, kind: AgentPaneTabKind, title: String, detail: String? = nil, workspace: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.workspace = workspace
        }
    }

    public struct Workspace: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var detail: String?

        public init(id: String, name: String, detail: String? = nil) {
            self.id = id
            self.name = name
            self.detail = detail
        }
    }

    public struct Page: Codable, Sendable, Equatable {
        public var url: String
        public var title: String?

        public init(url: String, title: String? = nil) {
            self.url = url
            self.title = title
        }
    }

    public var tabs: [Tab]
    public var workspaces: [Workspace]
    public var folders: [String]
    public var commands: [String]
    public var history: [Page]

    /// Bound used by native source queries before the DTO reaches the bridge.
    /// The web page applies its own validation and presentation cap.
    public static let maximumEntries = 40

    public init(tabs: [Tab] = [], workspaces: [Workspace] = [], folders: [String] = [], commands: [String] = [],
                history: [Page] = []) {
        self.tabs = tabs
        self.workspaces = workspaces
        self.folders = folders
        self.commands = commands
        self.history = history
    }
}
