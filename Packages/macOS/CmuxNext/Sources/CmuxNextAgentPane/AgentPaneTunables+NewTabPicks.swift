public import CmuxNextDesign

nonisolated extension AgentPaneTunables {
    /// Where a New Tab page's pick opens when the page shares its pane with another tab. Off (the
    /// default, Leo 2026-10-20): it replaces the page in its pane, like a browser's new tab, so no
    /// pane or divider moves. On: it lands where links do (`layout.linkPlacement`: the pane on the
    /// right, else a new split), as Lawrence asked on 2026-10-19.
    public static let newTabPicksFollowLinks = Tunable<Bool>.toggle(
        "newTab.picksFollowLinks", .tabs, "New tab picks open like links",
        help: "What a New Tab page opens (a chat, an address, a terminal) goes where Open Links and Files puts links, beside the page, instead of replacing the page in its pane.",
        default: false, code: "AgentPaneTunables.newTabPicksFollowLinks")
}
