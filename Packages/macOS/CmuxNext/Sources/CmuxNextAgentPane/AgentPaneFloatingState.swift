public import CmuxNextSettings

/// What Start Agent's floating chat (cx-b9qi) draws around its chat, pushed
/// as the `floatingState` event whenever it changes (the page's
/// floatingState.ts): whether the panel holds a running chat, floats over
/// other windows, and is folded to its compact bar.
public struct AgentPaneFloatingState: Equatable, Sendable {
    public var holding: Bool
    public var onTop: Bool
    public var collapsed: Bool

    public init(holding: Bool = false, onTop: Bool = true, collapsed: Bool = false) {
        self.holding = holding
        self.onTop = onTop
        self.collapsed = collapsed
    }

    var json: JSONValue { ["holding": .bool(holding), "onTop": .bool(onTop), "collapsed": .bool(collapsed)] }
    /// `quick.floatingState`'s reply: a page that loads after the last push reads it.
    var reply: [String: Any] { ["holding": holding, "onTop": onTop, "collapsed": collapsed] }
}

extension AgentPageEvent {
    /// The floating chat's state (`floatingState`).
    public static func floatingState(_ state: AgentPaneFloatingState) -> AgentPageEvent {
        AgentPageEvent(kind: "floatingState", value: state.json)
    }
}

extension AgentPaneFloatingState {
    /// Pushes `state` to `view`'s page.
    @MainActor public static func push(_ state: AgentPaneFloatingState, to view: AgentPaneView) {
        let event = AgentPageEvent.floatingState(state)
        view.deliver([event])
    }
}
