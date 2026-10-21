public import CmuxNextDesign

nonisolated extension AgentPaneTunables {
    /// The widget view under the New Tab composer (Leo 2026-10-18): a Projects card (this Mac and
    /// its recent projects) and a Needs you card (chats waiting on the user or that hit an error,
    /// each dismissable). Off by default, so the default page stays calm. Read as each page context
    /// is made (``AgentPaneNewTab``), so a toggle applies to the next new tab.
    public static let newTabWidgets = Tunable<Bool>.toggle(
        "newTab.widgets", .tabs, "New tab widgets",
        help: "Cards under the New Tab composer: this Mac's recent projects, and the chats that need you. Applies to the next new tab.",
        default: false, code: "AgentPaneTunables.newTabWidgets")

    /// The New Tab page's chats come from one store every page shares (Leo 2026-10-19: a torn-off
    /// window listed other chats than the main one, and a new page drew none until its connection
    /// answered; webviews newtab/chatStore.ts). On, each page lists only its own connection's chats,
    /// as before. Read as each page context is made, so a toggle applies to the next new tab.
    public static let newTabPrivateChatLists = Tunable<Bool>.toggle(
        "newTab.privateChatLists", .tabs, "New tab: own chat list per page",
        help: "Each New Tab page lists only the chats its own connection reported, instead of the list every page shares. Applies to the next new tab.",
        default: false, code: "AgentPaneTunables.newTabPrivateChatLists")
}
