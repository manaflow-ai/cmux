public import CmuxNextDesign

/// Which of the chat header's top-right icons show (webviews header/headerRelevance.ts). The
/// top-right thunderdome's contextual direction (Leo 2026-11-05: "what they do and when they
/// appear"). `standard` sets nothing new on the page: today's row.
public nonisolated enum AgentPaneHeaderIcons: String, Sendable, CaseIterable, TunableChoice {
    /// Today's row: the panel toggle, Needs You, Changes while it applies, Terminal, Browser, "...".
    case standard
    /// Each icon only while it is relevant to the chat (Terminal while its terminal is open, Browser
    /// while the chat has a page or its browser is open, Needs You with open asks); the rest wait in "...".
    case contextual
    /// As `contextual` at rest; the icons that are not relevant fade in at the row's leading end
    /// while the pointer is over the tools.
    case contextualPeek

    public var tunableTitle: String {
        switch self {
        case .standard: "Standard (today's row)"
        case .contextual: "Contextual (only when relevant)"
        case .contextualPeek: "Contextual, the rest on hover"
        }
    }
}

nonisolated extension AgentPaneTunables {
    /// The chat header's top-right icons (``AgentPaneHeaderIcons``). Pushed with the header state,
    /// so open chats follow a change at once.
    public static let headerIcons = Tunable<AgentPaneHeaderIcons>.choice(
        "agentChat.headerIcons.contextual", .panes, "Chat header icons: when they show",
        help: "Standard shows today's row. Contextual shows each top-right icon only while it is relevant to the chat (Terminal while its terminal is open, Browser while the chat has a page, Needs You with open asks); the rest are in the chat menu. Contextual, the rest on hover fades those in while the pointer is over the icons.",
        default: .standard, code: "AgentPaneTunables.headerIcons")
}
