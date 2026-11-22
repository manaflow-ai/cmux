/// How much of an agent pane anyone can see (``AgentPaneFramePacer/reportSight()``), for the socket that carries its
/// chat (``AgentPaneTransport/pageSight``).
///
/// Two levels, because the page reacts to them differently. `unseen`: nobody sees the pane, even when only another
/// window covers it; other chats' list notices are left out (``AcpmuxPaneSocket/setAsleep(_:)``), which the page
/// can't notice. `hidden`: the page's own document is hidden too (minimized, hidden, another Space; see
/// ``AgentPaneFramePacer/pageHidden(_:)``); only then is the chat's own stream left out
/// (``AcpmuxPaneSocket/setHidden(_:)``), since a page whose document is visible still checks that its stream moves.
public nonisolated struct AgentPaneSight: Equatable, Sendable {
    public var unseen: Bool
    public var hidden: Bool

    public init(unseen: Bool, hidden: Bool) {
        self.unseen = unseen || hidden
        self.hidden = hidden
    }

    public static let seen = AgentPaneSight(unseen: false, hidden: false)
}
