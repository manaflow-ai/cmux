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
    /// The "..." menu offers Move to Floating Chat (Start Agent's floating chat is on, cx-b9qi).
    public var floatingChat: Bool
    /// Debug Settings' Side sessions (/btw) is on (``AgentPaneTunables/sideSessions``): the composer
    /// offers `/btw`. The init reads the toggle unless given, so a watch that builds the state observes it.
    public var sideSessions: Bool
    /// The header offers Session Info (Debug Settings `agent.inspector`, cx-ncc.101), read like
    /// `sideSessions`. The page reads it as `inspector` (``json``), a wire name kept so a page and an
    /// app from either side of the rename still agree.
    public var sessionInfo: Bool
    /// The header's Browser opens the chat's page and Preview is no button of its own (Debug Settings
    /// `agentChat.browserOpensPreview`, on by default), read like `sideSessions`.
    public var browserOpensPreview: Bool
    /// Rises with every change the App sees: a `pane.tabState` reply that reaches the page after a
    /// newer push (two channels) is older, and the page keeps the newer state.
    public var version = 0

    public init(pinned: Bool = false, sideTabs: Bool = false, lit: [String] = [], floatingChat: Bool = false,
                sideSessions: Bool? = nil, sessionInfo: Bool? = nil, browserOpensPreview: Bool? = nil) {
        self.pinned = pinned
        self.sideTabs = sideTabs
        self.lit = lit
        self.floatingChat = floatingChat
        self.sideSessions = sideSessions ?? AgentPaneTunables.sideSessions.value
        self.sessionInfo = sessionInfo ?? AgentPaneTunables.sessionInfo.value
        self.browserOpensPreview = browserOpensPreview ?? AgentPaneTunables.browserOpensPreview.value
    }

    /// Whether the header shows the same thing, whatever the versions.
    public func shows(_ other: AgentPaneHeaderState) -> Bool {
        pinned == other.pinned && sideTabs == other.sideTabs && lit == other.lit && floatingChat == other.floatingChat
            && pullRequest == other.pullRequest && sideSessions == other.sideSessions && sessionInfo == other.sessionInfo
            && browserOpensPreview == other.browserOpensPreview
    }

    var reply: [String: Any] { json.foundationObject as? [String: Any] ?? [:] }

    /// `pullRequest` is always there, `null` when there is none, so the page drops a chip it kept.
    var json: JSONValue {
        ["pinned": .bool(pinned), "sideTabs": .bool(sideTabs), "lit": .array(lit.map(JSONValue.string)), "floatingChat": .bool(floatingChat),
         "sideSessions": .bool(sideSessions), "inspector": .bool(sessionInfo), "browserOpensPreview": .bool(browserOpensPreview), "version": JSONValue(version),
         "pullRequest": pullRequest?.json ?? .null]
    }
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
