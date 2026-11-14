public import CmuxNextDesign

/// The chat header's top-right controls (webviews header/headerTrio.ts), the top-right thunderdome's
/// variant D (Leo 2026-11-07: "The proposition of a 3-button only group is: 1. Ellipsis, for dealing
/// with your current chat 2. Session info 3. The grouped "new everything" which ALSO has a preview when
/// hovered over"). `standard` sets nothing new on the page: today's row.
public nonisolated enum AgentPaneHeaderControls: String, Sendable, CaseIterable, TunableChoice {
    /// Today's row: the panel toggle, Needs You, the quick action buttons and "...".
    case standard
    /// Three controls: "..." for the chat, the panel toggle, and one New split button whose click makes
    /// the last kind again (the New Tab page the first time) and whose chevron lists every kind with a preview.
    case trio

    public var tunableTitle: String {
        switch self {
        case .standard: "Standard (today's row)"
        case .trio: "Three controls (chat menu, panel, New)"
        }
    }
}

nonisolated extension AgentPaneTunables {
    /// The chat header's top-right controls (``AgentPaneHeaderControls``). Pushed with the header state,
    /// so open chats follow a change at once.
    public static let headerControls = Tunable<AgentPaneHeaderControls>.choice(
        "agentChat.headerControls", .panes, "Chat header: top-right controls",
        help: "Standard shows today's row. Three controls keeps only the chat menu, the panel toggle and one New button: a click makes the last kind again (a terminal, a browser, a side chat or the New Tab page), and its chevron lists every kind with a preview. The quick actions stay in the chat menu and on their shortcuts.",
        default: .standard, code: "AgentPaneTunables.headerControls")
}
