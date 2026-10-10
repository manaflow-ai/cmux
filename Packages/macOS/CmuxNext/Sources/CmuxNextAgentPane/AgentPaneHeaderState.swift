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

    public init(pinned: Bool = false, sideTabs: Bool = false, lit: [String] = []) {
        self.pinned = pinned
        self.sideTabs = sideTabs
        self.lit = lit
    }

    var reply: [String: Any] { ["pinned": pinned, "sideTabs": sideTabs, "lit": lit] }

    var json: JSONValue {
        ["pinned": .bool(pinned), "sideTabs": .bool(sideTabs), "lit": .array(lit.map(JSONValue.string))]
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
