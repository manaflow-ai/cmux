/// What a new tab or pane opens and where, tab moves, numbers, duplicates, restarts and icons
/// (cmux-window-rules `tabs`). Each refusal comes back as a key the app maps to its text.
extension WindowRules {
    // MARK: New tab kind

    /// What Cmd-T opens in a pane.
    public nonisolated enum NewTabKind: Decodable, Equatable, Sendable {
        case terminal
        /// A browser tab on `engine` (nil: `browser.defaultEngine`).
        case browser(engine: String?)
        case agent
        /// The New Tab page, to pick the kind.
        case page

        private enum CodingKeys: String, CodingKey { case kind, engine }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .kind) {
            case "terminal": self = .terminal
            case "browser": self = .browser(engine: try container.decodeIfPresent(String.self, forKey: .engine))
            case "agent": self = .agent
            case "page": self = .page
            case let other: throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "kind \(other)")
            }
        }
    }

    /// The facts of the tab a new tab opens next to.
    public nonisolated struct NewTabFacts: Encodable, Equatable, Sendable {
        /// `pty`, `browser`, or any other kind (nil: an empty pane).
        public var selectedKind: String?
        public var engine: String?
        public var localBrowser = false
        public var agent = false
        public var newTabPage = false
        public var user = false
        public var followsSetting = false
        public var canHostAgent = false

        public init(selectedKind: String?, engine: String?, localBrowser: Bool, agent: Bool, newTabPage: Bool,
                    user: Bool = false, followsSetting: Bool = false, canHostAgent: Bool = false) {
            self.selectedKind = selectedKind
            self.engine = engine
            self.localBrowser = localBrowser
            self.agent = agent
            self.newTabPage = newTabPage
            self.user = user
            self.followsSetting = followsSetting
            self.canHostAgent = canHostAgent
        }
    }

    /// What a new tab opens (`kind`), and the selected tab's own kind (`sameKind`); nil when the FFI does not answer.
    public func newTabKind(_ facts: NewTabFacts) -> (kind: NewTabKind, sameKind: NewTabKind)? {
        struct Reply: Decodable { var kind: NewTabKind, sameKind: NewTabKind }
        return call("window_tabs_new_tab_kind", facts, as: Reply.self).map { ($0.kind, $0.sameKind) }
    }

    // MARK: Browser

    /// Typed text resolved into a URL for one engine.
    public nonisolated struct Resolution: Encodable, Equatable, Sendable {
        public var url: String
        public var agentRefuses: Bool
        /// `cmuxPage`, `browserSettings`, `passwordsPage`, `chromium`; nil for any other URL.
        public var route: String?
        /// The cmux page of a `cmuxPage` route.
        public var page: String?

        public init(url: String, agentRefuses: Bool, route: String?, page: String?) {
            self.url = url
            self.agentRefuses = agentRefuses
            self.route = route
            self.page = page
        }
    }

    /// The facts of an `openBrowser` run's `url` and `engine` arguments.
    public nonisolated struct BrowserOpenFacts: Encodable, Equatable, Sendable {
        public var hasText: Bool
        public var engine: String?
        public var agent: Bool
        public var chromiumInternal: Bool
        public var cmuxOwned: Bool
        public var webkit: Resolution?
        public var chromium: Resolution?

        public init(hasText: Bool, engine: String?, agent: Bool, chromiumInternal: Bool, cmuxOwned: Bool,
                    webkit: Resolution?, chromium: Resolution?) {
            self.hasText = hasText
            self.engine = engine
            self.agent = agent
            self.chromiumInternal = chromiumInternal
            self.cmuxOwned = cmuxOwned
            self.webkit = webkit
            self.chromium = chromium
        }
    }

    /// What `openBrowser` does with its arguments.
    public nonisolated enum BrowserOpen: Decodable, Equatable, Sendable {
        /// `invalidUrl` or `agentChromiumPage`.
        case refuse(String)
        case open(url: String?, engine: String?)
        case browserSettings
        case passwordsPage

        private enum CodingKeys: String, CodingKey { case plan, reason, url, engine }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .plan) {
            case "refuse": self = .refuse(try container.decode(String.self, forKey: .reason))
            case "open": self = .open(url: try container.decodeIfPresent(String.self, forKey: .url),
                                      engine: try container.decodeIfPresent(String.self, forKey: .engine))
            case "browserSettings": self = .browserSettings
            case "passwordsPage": self = .passwordsPage
            case let other: throw DecodingError.dataCorruptedError(forKey: .plan, in: container, debugDescription: "plan \(other)")
            }
        }
    }

    public func browserOpen(_ facts: BrowserOpenFacts) -> BrowserOpen? {
        call("window_tabs_browser_open", facts, as: BrowserOpen.self)
    }

    /// The facts of where a new browser tab opens.
    public nonisolated struct BrowserPlacementFacts: Encodable, Equatable, Sendable {
        public var scripted, allowsViewChange, focusedHere, besideCaller, newColumnBeside, opensInBackground: Bool

        public init(scripted: Bool, allowsViewChange: Bool, focusedHere: Bool, besideCaller: Bool, newColumnBeside: Bool, opensInBackground: Bool) {
            self.scripted = scripted
            self.allowsViewChange = allowsViewChange
            self.focusedHere = focusedHere
            self.besideCaller = besideCaller
            self.newColumnBeside = newColumnBeside
            self.opensInBackground = opensInBackground
        }
    }

    /// Whether a new browser tab opens behind, and whether it is an agent's (no saved password fills in it).
    public nonisolated struct BrowserPlacement: Decodable, Equatable, Sendable {
        public var background: Bool
        public var agentDriven: Bool
    }

    public func browserPlacement(_ facts: BrowserPlacementFacts) -> BrowserPlacement? {
        call("window_tabs_browser_placement", facts, as: BrowserPlacement.self)
    }

    /// The facts of Open in Chromium / Open in WebKit.
    public nonisolated struct ReopenFacts: Encodable, Equatable, Sendable {
        public var isBrowser: Bool
        public var current: String?
        public var target: String
        public var proxied: Bool
        public var chromiumUnavailable: Bool

        public init(isBrowser: Bool, current: String?, target: String, proxied: Bool, chromiumUnavailable: Bool) {
            self.isBrowser = isBrowser
            self.current = current
            self.target = target
            self.proxied = proxied
            self.chromiumUnavailable = chromiumUnavailable
        }
    }

    /// `refuse` (with `reason`: `notABrowserTab`, `proxiedTabStaysInChromium`, `chromiumUnavailable`), `same` or `reopen`.
    public nonisolated struct Reopen: Decodable, Equatable, Sendable {
        public var decision: String
        public var reason: String?
    }

    public func reopen(_ facts: ReopenFacts) -> Reopen? {
        call("window_tabs_reopen", facts, as: Reopen.self)
    }

    // MARK: Terminal as Chat

    /// Open Terminal as Chat's route.
    public nonisolated enum TerminalChat: Decodable, Equatable, Sendable {
        case noSession
        case unsupportedHarness
        /// A chat resumes `session` of `harness` over ACP.
        case adopt(harness: String, session: String)

        private enum CodingKeys: String, CodingKey { case route, harness, session }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .route) {
            case "noSession": self = .noSession
            case "unsupportedHarness": self = .unsupportedHarness
            case "adopt": self = .adopt(harness: try container.decode(String.self, forKey: .harness),
                                        session: try container.decode(String.self, forKey: .session))
            case let other: throw DecodingError.dataCorruptedError(forKey: .route, in: container, debugDescription: "route \(other)")
            }
        }
    }

    private nonisolated struct AgentRequest: Encodable { var agent: String?, session: String? }
    private nonisolated struct AgentReply: Decodable { var chat: TerminalChat, harness: String? }

    /// The route of a terminal whose agent `agent` reports the harness's session id `session`.
    public func terminalChat(agent: String?, session: String?) -> TerminalChat? {
        call("window_tabs_terminal_chat", AgentRequest(agent: agent, session: session), as: AgentReply.self)?.chat
    }

    /// The acpmux harness of a terminal agent's name (`claude`, `codex`), nil for agents acpmux does not adopt.
    public func agentHarness(_ agent: String?) -> String? {
        call("window_tabs_terminal_chat", AgentRequest(agent: agent, session: nil), as: AgentReply.self)?.harness
    }

    // MARK: Duplicate, numbers, moves

    /// The facts of one tab Duplicate Tab acts on.
    public nonisolated struct DuplicateFacts: Encodable, Equatable, Sendable {
        public var browser, localBrowser, agent, localPage, page: Bool

        public init(browser: Bool, localBrowser: Bool, agent: Bool, localPage: Bool, page: Bool) {
            self.browser = browser
            self.localBrowser = localBrowser
            self.agent = agent
            self.localPage = localPage
            self.page = page
        }
    }

    /// What Duplicate Tab does with each tab (`browser`, `localBrowser`, `agent`, `skip`, `terminal`); nil when
    /// refused (every tab is a page tab) or the FFI does not answer.
    public func duplicate(_ tabs: [DuplicateFacts]) -> [String]? {
        struct Request: Encodable { var tabs: [DuplicateFacts] }
        struct Reply: Decodable { var actions: [String]? }
        return call("window_tabs_duplicate", Request(tabs: tabs), as: Reply.self)?.actions
    }

    private nonisolated struct NumberRequest: Encodable { var number: Int, count: Int }
    private nonisolated struct IndexReply: Decodable { var index: Int? }

    /// The tab a select-by-number picks among `count` shown tabs (9: the last); nil without one.
    public func tabByNumber(_ number: Int, count: Int) -> Int? {
        call("window_tabs_by_number", NumberRequest(number: number, count: count), as: IndexReply.self)?.index
    }

    /// The pane a focus-by-number picks among `count` panes (9: the last); nil for a number with no pane.
    public func paneByNumber(_ number: Int, count: Int) -> Int? {
        call("window_panes_by_number", NumberRequest(number: number, count: count), as: IndexReply.self)?.index
    }

    /// The facts of a Move Tab (or Tab Group) to New Split.
    public nonisolated struct MoveToSplitFacts: Encodable, Equatable, Sendable {
        public var direction: String?
        public var group: Bool
        public var tabsInPane: Int
        public var chatDock: Bool
        public var chat: Bool
        public var dockColumn: Bool

        public init(direction: String?, group: Bool, tabsInPane: Int = 0, chatDock: Bool, chat: Bool = false, dockColumn: Bool = false) {
            self.direction = direction
            self.group = group
            self.tabsInPane = tabsInPane
            self.chatDock = chatDock
            self.chat = chat
            self.dockColumn = dockColumn
        }
    }

    /// `refuse`, `split` on `edge` (`left`, `right`, `top`, `bottom`), or `columnAfterDock`.
    public nonisolated struct MoveToSplit: Decodable, Equatable, Sendable {
        public var decision: String
        public var edge: String?
    }

    public func moveToSplit(_ facts: MoveToSplitFacts) -> MoveToSplit? {
        call("window_tabs_move_to_split", facts, as: MoveToSplit.self)
    }

    /// The collapsed state a collapse, expand or toggle (`value` nil) sets on a group now `current`; nil: no change.
    public func groupCollapse(_ value: Bool?, current: Bool) -> Bool? {
        struct Request: Encodable { var value: Bool?, current: Bool }
        struct Reply: Decodable { var collapsed: Bool? }
        return call("window_tabs_group_collapse", Request(value: value, current: current), as: Reply.self)?.collapsed
    }

    // MARK: Restart, icons, identifiers

    /// Why a tab cannot restart (`notATerminal`, `tabNotDead`), nil when it can; `answered` false when the FFI does not answer.
    public func restartRefusal(pty: Bool, dead: Bool, failed: Bool) -> (refusal: String?, answered: Bool) {
        struct Request: Encodable { var pty: Bool, dead: Bool, failed: Bool }
        struct Reply: Decodable { var refusal: String? }
        guard let reply = call("window_tabs_restart", Request(pty: pty, dead: dead, failed: failed), as: Reply.self) else { return (nil, false) }
        return (reply.refusal, true)
    }

    /// The undo step an icon change from `previous` to `icon` offers: `set`, `remove`, or nil for none.
    public func iconUndo(user: Bool, previous: String?, icon: String?) -> String? {
        struct Request: Encodable { var user: Bool, previous: String?, icon: String? }
        struct Reply: Decodable { var undo: String? }
        return call("window_tabs_icon_undo", Request(user: user, previous: previous, icon: icon), as: Reply.self)?.undo
    }

    /// Copy Workspace ID(s): one block per workspace public id; with `refs`, the `--target` form first.
    public func workspaceIDText(_ workspaces: [String], refs: Bool) -> String? {
        struct Request: Encodable { var workspaces: [String], refs: Bool }
        struct Reply: Decodable { var text: String }
        return call("window_tabs_identifiers", Request(workspaces: workspaces, refs: refs), as: Reply.self)?.text
    }

    /// Copy IDs on a tab: its workspace (when known), pane and tab ids.
    public func identifiersText(workspace: String?, pane: String, surface: String) -> String? {
        struct Request: Encodable { var workspace: String?, pane: String, surface: String }
        struct Reply: Decodable { var text: String }
        return call("window_tabs_identifiers", Request(workspace: workspace, pane: pane, surface: surface), as: Reply.self)?.text
    }
}
