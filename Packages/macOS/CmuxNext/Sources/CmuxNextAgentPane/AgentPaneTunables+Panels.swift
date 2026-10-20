public import CmuxNextDesign

extension AgentPaneTunables {
    /// Panels open as tabs on the right (Lucas 2026-10-17): with a panel beside the chat, the header's
    /// Terminal and Browser open a tab in that panel's pane instead of another split, and the header
    /// drops its quick-action buttons into "..." (the page's header/ChatHeaderTools.tsx), so the right
    /// side's own tab strip is where new tabs go. Off keeps every split and button as before.
    public static let panelTabs = Tunable<Bool>.toggle(
        "agentChat.panelTabs", .panes, "Panels open as tabs on the right",
        help: "With a panel beside an agent chat, Terminal and Browser add a tab to it instead of another split, and the chat header keeps its tools in its ... menu.",
        default: false, code: "AgentPaneTunables.panelTabs")

    /// The agent chat's side column on Opt-Cmd-B (Lucas 2026-10-17, after T3 Code's surface panel): Toggle
    /// Right Sidebar runs the focused chat's New tab / Hide tabs, so a column of panes opens beside the
    /// chat (a New Tab page whose tiles open a terminal, browser, files or changes there) and hides
    /// again, closing nothing. Off, Toggle Right Sidebar reports that cmux-next has no right sidebar.
    /// Read on every press.
    public static let sideColumn = Tunable<Bool>.toggle(
        "agentChat.sideColumn", .panes, "Opt-Cmd-B opens the chat's side column",
        help: "Toggle Right Sidebar shows and hides a column of panes beside the focused agent chat, starting with a page of tiles for a terminal, browser, files or changes.",
        default: false, code: "AgentPaneTunables.sideColumn")

    /// A chat that shares its pane with other tabs docks left when Files, Changes or Preview opens
    /// beside it, as a chat alone in its pane does (Lucas 2026-10-17): the view lands on its right and
    /// the other tabs stay with it. Off, such a chat keeps its pane and the view takes a new column,
    /// which on a screen without columns filled the window and scrolled the chat out of view.
    public static let dockBesideTabs = Tunable<Bool>.toggle(
        "agentChat.dockBesideTabs", .panes, "Chat docks left beside other tabs",
        help: "Files, Changes or Preview opened from a chat that shares its pane with other tabs docks the chat left and opens on its right, as for a chat alone in its pane.",
        default: false, code: "AgentPaneTunables.dockBesideTabs")
}
