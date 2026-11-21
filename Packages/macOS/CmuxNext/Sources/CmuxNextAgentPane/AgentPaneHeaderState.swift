public import CmuxNextDaemon
public import CmuxNextSettings

/// What the chat header shows from the chat's tab, read with `pane.tabState` and pushed as the
/// `headerState` event when it changes (the page's header/headerState.ts): the pin the "..." menu's
/// labels read, whether the panes beside the chat show ([+] New tab reads Hide tabs), and the
/// header splits whose button is lit because the split it opened is open (cx-00n1).
public struct AgentPaneHeaderState: Equatable, Sendable {
    public var pinned: Bool
    public var sideTabs: Bool
    /// The header actions (`splitRight`, `splitBrowserRight`) whose split is open, sorted.
    public var lit: [String]
    /// The chat folder's branch's pull request, when it has one (cx-tcwj).
    public var pullRequest: AgentPanePullRequest?
    /// The chat's workspace, for the glass toolbar's title (`experiments.glassToolbarGroups`); nil
    /// when the store does not list the chat.
    public var workspace: AgentPaneHeaderWorkspace?
    /// The "..." menu offers Move to Floating Chat (Start Agent's floating chat is on, cx-b9qi).
    public var floatingChat: Bool
    /// The header offers Session Info (Debug Settings `agent.sessionInfo`, cx-ncc.101). The init
    /// reads the toggle unless given, so a watch that builds the state observes it. The page reads it as `inspector` (``json``), a wire name kept so a page and an
    /// app from either side of the rename still agree.
    public var sessionInfo: Bool
    /// Which top-right controls show (Debug Settings `agentChat.headerControls`), read like `sessionInfo`;
    /// the page's header/headerTrio.ts applies it.
    public var headerControls: AgentPaneHeaderControls
    /// How the header's icons move (Debug Settings `agentChat.headerMotion`, ``AgentPaneHeaderMotion``), read like `sessionInfo`.
    public var headerMotion: AgentPaneHeaderMotion
    /// Rises with every change the App sees: a `pane.tabState` reply that reaches the page after a
    /// newer push (two channels) is older, and the page keeps the newer state.
    public var version = 0

    public init(pinned: Bool = false, sideTabs: Bool = false, lit: [String] = [], floatingChat: Bool = false,
                sessionInfo: Bool? = nil, headerControls: AgentPaneHeaderControls? = nil,
                headerMotion: AgentPaneHeaderMotion? = nil) {
        self.pinned = pinned
        self.sideTabs = sideTabs
        self.lit = lit
        self.floatingChat = floatingChat
        self.sessionInfo = sessionInfo ?? AgentPaneTunables.sessionInfo.value
        self.headerControls = headerControls ?? AgentPaneTunables.headerControls.value
        self.headerMotion = headerMotion ?? AgentPaneTunables.headerMotion.value
    }

    /// Whether the header shows the same thing, whatever the versions.
    public func shows(_ other: AgentPaneHeaderState) -> Bool {
        pinned == other.pinned && sideTabs == other.sideTabs && lit == other.lit && floatingChat == other.floatingChat
            && pullRequest == other.pullRequest && workspace == other.workspace && sessionInfo == other.sessionInfo
            && headerControls == other.headerControls
            && headerMotion == other.headerMotion
    }

    var reply: [String: Any] { json.foundationObject as? [String: Any] ?? [:] }

    /// `pullRequest` and `workspace` are always there, `null` when there is none, so the page drops what it kept.
    var json: CmuxNextSettings.JSONValue {
        ["pinned": .bool(pinned), "sideTabs": .bool(sideTabs), "lit": .array(lit.map(CmuxNextSettings.JSONValue.string)), "floatingChat": .bool(floatingChat),
         "inspector": .bool(sessionInfo), "headerControls": .string(headerControls.rawValue),
         "headerMotion": .string(headerMotion.rawValue), "version": CmuxNextSettings.JSONValue(version),
         "pullRequest": pullRequest?.json ?? .null, "workspace": workspace?.json ?? .null]
    }
}

/// The chat's workspace as its header shows it: the workspace's shown name and how many agent chat
/// tabs it holds (the page's `workspace: {title, chats}`).
public struct AgentPaneHeaderWorkspace: Equatable, Sendable {
    public var title: String
    public var chats: Int

    public init(title: String, chats: Int) {
        self.title = title
        self.chats = chats
    }

    /// `workspace`'s shown name and its agent chat tabs (a walk of that workspace's tabs only).
    @MainActor public init(_ workspace: WorkspaceModel) {
        self.init(title: workspace.displayName, chats: workspace.agentChatCount)
    }

    var json: CmuxNextSettings.JSONValue { ["title": .string(title), "chats": CmuxNextSettings.JSONValue(chats)] }
}

extension AgentPageEvent {
    /// The chat header's state (`headerState`).
    public static func headerState(_ state: AgentPaneHeaderState) -> AgentPageEvent {
        AgentPageEvent(kind: "headerState", value: state.json)
    }
}

extension AgentPaneHeaderState {
    /// Pushes `state` to `view`'s page (not an AgentPaneView extension: that type is at its size limit).
    @MainActor public static func push(_ state: AgentPaneHeaderState, to view: AgentPaneView) {
        let event = AgentPageEvent.headerState(state)
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyHeaderState?.(\(event.value.compactText));"])
    }
}
