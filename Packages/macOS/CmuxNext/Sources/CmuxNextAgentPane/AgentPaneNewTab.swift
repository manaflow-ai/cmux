import CmuxNextDesign
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
    /// The machine the page runs on, for its machine chip: this Mac's name once the launch's read
    /// answered (``AgentPaneModel/localMachineDisplayName``), so the chip names it on the first
    /// frame instead of "This Mac" until the handshake. nil on another machine, whose handshake
    /// names it, or before the read answers.
    public var host: String?
    /// The newest chats a page on this Mac listed last, as JSON text (`{sessions, device}`, from
    /// `newTab.warm`): the page lists them on its first frame instead of an empty list until its
    /// own daemon connection lists them. nil on another machine or before any page listed chats.
    public var warm: String?
    /// The tab the page opened from, as the location bar shows it (its URL or
    /// folder): in the field and selected, so typing replaces it.
    public var location: String?
    /// What the location bar suggests besides the typed text.
    public var omnibar: AgentPaneOmnibar
    /// Recent local project folders from agent history, classic sessions and git roots.
    public var projects: [String]
    /// The design to show; nil is the page's default (B).
    public var layout: AgentPaneNewTabLayout?
    /// The template (`tabs.newTabTemplate`: "minimal", "cards", "default", "composer", "threads",
    /// "console", "classic" or "terminal"); nil follows `layout`. The page validates it.
    public var template: String?
    /// The agent last picked.
    public var lastAgent: String?
    /// The harness and model picked last, anywhere and per folder; nil when none was.
    public var lastPicks: AgentPaneLastPicks?
    /// The home folder, so the field reads `~/path` as a folder.
    public var home: String?
    /// The project of the chat the person last picked and started (`newTab.remember` `started`):
    /// where a page with no folder of its own starts. nil on another machine or before any start.
    public var startedProject: String?
    /// Identifies the opening whose focused field must acknowledge readiness.
    public var inputToken: String?
    /// false: the page leaves its field unfocused (Cmd-L opened it for the omnibar, cx-e2aa);
    /// nil focuses it.
    public var focusesField: Bool?
    /// The workspace's tabs to move into this page's pane (`tab.jump` `here`): set when a split
    /// opened the page (cx-jfo7); nil shows no Open Tabs list.
    public var openTabs: [AgentPaneOmnibar.Tab]?
    /// true: the page is agent history (Show Agent History, `agentHistory.show`, cx-zlnl), every chat on this
    /// device with nothing to type; nil is the New Tab page.
    public var history: Bool?
    /// true: Integrate a harness was dismissed for good (`newTab.remember` `harnessHint: "dismissed"`); nil offers it
    /// when no harness is installed.
    public var harnessHintDismissed: Bool?
    /// true: the page shows the widget view under its composer (Debug Settings `newTab.widgets`,
    /// ``AgentPaneTunables/newTabWidgets``); nil shows none.
    public var widgets: Bool?
    /// The Minimal layout's widgets the user turned on (`tabs.newTabWidgets.*`: "greeting" (the
    /// headline asking what to work on), "projects", "actions", "chats", "styleDots"); Minimal draws
    /// the composer and only these besides. nil is Settings' defaults (none). The other layouts ignore it.
    /// The page validates it.
    public var pageWidgets: [String]?
    /// The weather widget's last reading (`tabs.newTabWidgets.weather`, ``AgentPaneNewTabWeather``);
    /// nil while it is off or before the first reading. The page dims one older than its refresh.
    public var weather: AgentPaneNewTabWeather?
    /// true: `tabs.newTabWidgets.greeting` is false in cmux.json, not the default
    /// (``NewTabWidgetSettings/greetingTurnedOff``): Minimal keeps no room over the composer for the
    /// headline, so the composer stays where it sat with the greeting off; nil keeps the room.
    public var headlineOff: Bool?
    /// true: the page lists only its own connection's chats, not the store every page shares
    /// (Debug Settings `newTab.privateChatLists`, ``AgentPaneTunables/newTabPrivateChatLists``).
    public var privateChatLists: Bool?
    /// false: Show All Chats on New Tab is off (`sidebar.showChats`): the page lists the recent
    /// chats only, never All chats; nil lists All chats where the template does.
    public var allChats: Bool?

    public init(kind: AgentPaneTabKind, hotkeys: [AgentPaneTabKind: String] = [:], cwd: String? = nil,
                location: String? = nil, omnibar: AgentPaneOmnibar = AgentPaneOmnibar(), projects: [String] = [],
                layout: AgentPaneNewTabLayout? = nil,
                lastAgent: String? = nil, lastPicks: AgentPaneLastPicks? = nil, home: String? = nil,
                template: String? = nil, widgets: Bool? = nil, pageWidgets: [String]? = nil) {
        self.kind = kind
        self.hotkeys = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        self.cwd = cwd
        self.location = location
        self.omnibar = omnibar
        // Keep the host DTO lossless. The web page owns presentation limits and
        // validation after the Codable handshake crosses the bridge.
        self.projects = projects
        self.layout = layout
        self.template = template
        self.pageWidgets = pageWidgets
        self.lastAgent = lastAgent
        self.lastPicks = lastPicks
        self.home = home
        self.inputToken = nil
        // nil follows the Debug Settings toggle, read as each page context is made.
        self.widgets = (widgets ?? AgentPaneTunables.newTabWidgets.value) ? true : nil
        self.privateChatLists = AgentPaneTunables.newTabPrivateChatLists.value ? true : nil
    }
}

extension AgentPaneNewTab {
    /// The newest chats a local page posted (`newTab.warm`), for the next page's ``warm``.
    @MainActor public internal(set) static var warmed: String?
    /// The largest `newTab.warm` the host keeps.
    nonisolated public static let maximumWarmBytes = 512 * 1024

    /// The page as it opens on this Mac (`local`): this Mac's name as its `host` once the launch's
    /// read has answered, and the newest chats a page listed as its ``warm``, so its first frame
    /// names the Mac and lists the chats. Every opening (Cmd-T, +, a new workspace, a split, an
    /// adopted spare) makes its context here, so each decides from the same snapshot.
    @MainActor public func warmedOnThisMac(_ local: Bool = true) -> AgentPaneNewTab {
        var page = self
        if local {
            page.host = AgentPaneModel.localMachineDisplayName
            page.warm = Self.warmed
        } else {
            // Another machine's page lists its own chats, never the ones this Mac's pages share
            // (webviews newtab/chatStore.ts), not even before its handshake names its origin.
            page.privateChatLists = true
        }
        return page
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
        /// A browser tab's favicon as a `data:image/png` URL (the page allows only inline images).
        public var icon: String?

        public init(id: String, kind: AgentPaneTabKind, title: String, detail: String? = nil, workspace: String? = nil,
                    icon: String? = nil) {
            self.id = id
            self.kind = kind
            self.title = title
            self.detail = detail
            self.workspace = workspace
            self.icon = icon
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
        /// The page's site favicon as a `data:image/png` URL.
        public var icon: String?

        public init(url: String, title: String? = nil, icon: String? = nil) {
            self.url = url
            self.title = title
            self.icon = icon
        }
    }

    /// A host-owned action the omnibar may invoke by id.
    public struct Action: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var detail: String?
        public var keywords: [String]

        public init(id: String, title: String, detail: String? = nil, keywords: [String] = []) {
            self.id = id
            self.title = title
            self.detail = detail
            self.keywords = keywords
        }
    }

    /// Bound for newly introduced recent project and action suggestions.
    public static let maximumEntries = 40

    public var tabs: [Tab]
    public var workspaces: [Workspace]
    public var folders: [String]
    /// Recent local project folders for the agent picker. This is separate
    /// from `folders`, which is kept for terminal suggestions.
    public var projects: [String]
    public var actions: [Action]
    public var commands: [String]
    public var history: [Page]

    public init(tabs: [Tab] = [], workspaces: [Workspace] = [], folders: [String] = [], projects: [String] = [],
                actions: [Action] = [], commands: [String] = [], history: [Page] = []) {
        let cap = Self.maximumEntries
        self.tabs = tabs
        self.workspaces = workspaces
        self.folders = folders
        self.projects = Array(projects.prefix(cap))
        self.actions = Array(actions.prefix(cap))
        self.commands = commands
        self.history = history
    }

    private enum CodingKeys: String, CodingKey { case tabs, workspaces, folders, projects, actions, commands, history }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tabs: try values.decodeIfPresent([Tab].self, forKey: .tabs) ?? [],
            workspaces: try values.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? [],
            folders: try values.decodeIfPresent([String].self, forKey: .folders) ?? [],
            projects: try values.decodeIfPresent([String].self, forKey: .projects) ?? [],
            actions: try values.decodeIfPresent([Action].self, forKey: .actions) ?? [],
            commands: try values.decodeIfPresent([String].self, forKey: .commands) ?? [],
            history: try values.decodeIfPresent([Page].self, forKey: .history) ?? []
        )
    }

    var reply: [String: Any] {
        func optional(_ pairs: [(String, String?)]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: pairs.compactMap { key, value in value.map { (key, $0 as Any) } })
        }
        return [
            "tabs": tabs.map {
                optional([("id", $0.id), ("kind", $0.kind.rawValue), ("title", $0.title), ("detail", $0.detail),
                          ("workspace", $0.workspace), ("icon", $0.icon)])
            },
            "workspaces": workspaces.map { optional([("id", $0.id), ("name", $0.name), ("detail", $0.detail)]) },
            "folders": folders,
            "projects": projects,
            "actions": actions.map {
                optional([("id", $0.id), ("title", $0.title), ("detail", $0.detail)])
                    .merging(["keywords": $0.keywords]) { left, _ in left }
            },
            "commands": commands,
            "history": history.map { optional([("url", $0.url), ("title", $0.title), ("icon", $0.icon)]) },
        ]
    }
}
