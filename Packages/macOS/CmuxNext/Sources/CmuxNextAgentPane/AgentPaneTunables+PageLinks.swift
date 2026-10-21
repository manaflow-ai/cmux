public import CmuxNextDesign

nonisolated extension AgentPaneTunables {
    /// Where what a page opens lands: a link in an agent chat (its pull request too), Home, a
    /// Markdown or code page, a New Tab page's pick. Off (the default, Leo 2026-10-20): a tab in the
    /// page's own pane, so no pane or divider moves. On: where `layout.linkPlacement` puts a
    /// terminal's Cmd-click (the pane on the right, else a new split), as Lawrence set it on 2026-10-19.
    public static let pagesFollowLinkPlacement = Tunable<Bool>.toggle(
        "links.pagesFollowPlacement", .tabs, "Links from pages open like Cmd-click",
        help: "What an agent chat, Home, the New Tab page or a Markdown or code page opens goes where Open Links and Files puts a terminal's Cmd-click, beside the page, instead of a tab in the page's pane.",
        default: false, code: "AgentPaneTunables.pagesFollowLinkPlacement")
}
