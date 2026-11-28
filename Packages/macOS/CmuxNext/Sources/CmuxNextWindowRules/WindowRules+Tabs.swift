/// What a new tab or pane opens and where, tab moves, numbers, duplicates, restarts and icons
/// (cmux-window-rules `tabs`). Each refusal comes back as a key the app maps to its text.
extension WindowRules {
    // MARK: New tab kind

    /// What a new tab opens (`kind`), and the selected tab's own kind (`sameKind`); nil when the FFI does not answer.
    public func newTabKind(_ facts: NewTabFacts) -> (kind: NewTabKind, sameKind: NewTabKind)? {
        struct Reply: Decodable { var kind: NewTabKind, sameKind: NewTabKind }
        guard let reply = call("window_tabs_new_tab_kind", facts, as: Reply.self) else { return nil }
        // Re-pin bridge (cmux#48416): the pinned app FFI predates `tabs::new_tab_kind`'s `terminal_first`, so a
        // terminal-first person's Cmd-T is answered here the way that rule does. Delete once the FFI re-pin lands.
        if facts.terminalFirst, facts.user, facts.followsSetting, reply.kind == .page { return (.terminal, reply.sameKind) }
        return (reply.kind, reply.sameKind)
    }

    // MARK: Browser

    public func browserOpen(_ facts: BrowserOpenFacts) -> BrowserOpen? {
        call("window_tabs_browser_open", facts, as: BrowserOpen.self)
    }

    public func browserPlacement(_ facts: BrowserPlacementFacts) -> BrowserPlacement? {
        call("window_tabs_browser_placement", facts, as: BrowserPlacement.self)
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

    /// A chat's session handed to a new terminal, until that terminal's hooks report it: `tab` nil
    /// while the chat's run stops. Over at `deadline` (seconds since 1970), reported or not. `machine`
    /// is the machine the terminal tab was made on, so it is looked up there only (a fork keeps its ids).
    public nonisolated struct HandOff: Codable, Equatable, Sendable {
        public var deadline: Double
        public var tab: String?
        public var machine: String?

        public init(deadline: Double, tab: String? = nil, machine: String? = nil) {
            self.deadline = deadline
            self.tab = tab
            self.machine = machine
        }
    }

    public func terminalChatToggle(_ facts: ToggleFacts) -> TerminalChatToggle? {
        call("window_tabs_terminal_chat_toggle", facts, as: TerminalChatToggle.self)
    }

    // MARK: Duplicate, numbers, moves

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
