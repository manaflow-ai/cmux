import CmuxHomeCore
import CmuxNextHomeEngine

extension HomeService {
    /// The conversations Home shows unread (the list's dots: unread messages or Mark as Unread,
    /// never muted), the one source of Home's unread indicator outside Home: the sidebar's Home
    /// item, a Home tab's dot and the Dock count all read it. Observable (the inbox owners' rows,
    /// the store's rows and the marks).
    var unreadConversations: [ConversationID] { groupMuting.unreadConversations }

    /// Whether a tab shows Home: the Home page tab (`home.tab`), the docked Home, or the Home app.
    static func isHomeTab(page: String?, app: String?) -> Bool {
        if let page { return page == InternalPageID.homeTab.rawValue || page == HomeDock.page }
        return app == TopPageRoute.homeAppID
    }
}
