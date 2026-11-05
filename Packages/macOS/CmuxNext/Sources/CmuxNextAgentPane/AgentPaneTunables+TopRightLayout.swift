public import CmuxNextDesign

/// How the chat header's top-right icons are laid out (webviews header/TopRightLayouts.tsx): the
/// top-right thunderdome's consolidate-and-morph direction (Leo 2026-11-05: "the top right icons
/// and what they do and when they appear"). `row` sets nothing new on the page: today's row.
public nonisolated enum AgentPaneTopRightLayout: String, Sendable, CaseIterable, TunableChoice {
    /// Today's row: one button per quick action.
    case row
    /// One control that expands into the set; the icon you pick becomes the control's face while
    /// its pane is open, as the pane's tab is.
    case morph
    /// The row while nothing is open beside the chat; once a pane is, its icons draw as tabs at the
    /// header's trailing edge, against the right pane's own tab strip.
    case tabStrip
    /// One recent-panes button, as a browser's recent tabs: open panes first, then recent, then the rest.
    case dock

    public var tunableTitle: String {
        switch self {
        case .row: "Row (today's)"
        case .morph: "Morph (one control that expands)"
        case .tabStrip: "Tab strip (icons become tabs once open)"
        case .dock: "Dock (recent panes)"
        }
    }
}

nonisolated extension AgentPaneTunables {
    /// The chat header's top-right layout (``AgentPaneTopRightLayout``). Pushed with the header
    /// state, so open chats follow a change at once.
    public static let topRightLayout = Tunable<AgentPaneTopRightLayout>.choice(
        "agentChat.topRight.consolidate", .panes, "Chat header icons: consolidated layout",
        help: "Row shows today's buttons. Morph folds them into one control that expands into the set; the icon you pick becomes the control while its pane is open. Tab strip keeps the row until a pane opens, then draws the open panes' icons as tabs at the header's trailing edge. Dock is one recent-panes button, as a browser's recent tabs.",
        default: .row, code: "AgentPaneTunables.topRightLayout")
}
