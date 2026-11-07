public import CmuxNextDesign

nonisolated extension AgentPaneTunables {
    /// Where a New Tab page's pick opens when the page shares its pane with another tab. On (the
    /// default, Lawrence 2026-10-19, restated 2026-11-05: "New Tab page click opens in the pane to the
    /// right, not the same pane"): it lands where links do (`layout.linkPlacement`: the pane on the
    /// right, else a new split). Off (Leo 2026-10-20): it replaces the page in its pane, like a
    /// browser's new tab, so no pane or divider moves.
    public static let newTabPicksFollowLinks = Tunable<Bool>.toggle(
        "newTab.picksFollowLinks", .tabs, "New tab picks open like links",
        help: "What a New Tab page opens (a chat, an address, a terminal) goes where Open Links and Files puts links, beside the page, instead of replacing the page in its pane.",
        default: true, code: "AgentPaneTunables.newTabPicksFollowLinks")
}
