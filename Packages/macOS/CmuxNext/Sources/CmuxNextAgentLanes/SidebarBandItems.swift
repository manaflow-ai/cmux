public import CmuxNextActions
public import CmuxNextSidebar

/// The values of the sidebar band's items (`SidebarModel.itemInfo`), made from the App's state: the built-ins, the
/// apps and the workspaces a layout places, and the built-ins the list draws in a group or a machine list.
@MainActor
public struct SidebarBandItems {
    public init() {}
    /// The registry action each built-in runs.
    public static let builtInActions: [SidebarBuiltIn: ActionID] = [
        .home: "home.show",
        .settings: "openSettings",
        .account: "sidebar.profileMenu", // the profile control (amendment 2); Accounts stays `accounts.show`
        .notifications: "showNotifications",
        .history: "history.show",
        .bookmarks: "bookmark.manager",
        .appStore: "appStore.show",
        .newTerminal: "newSurface",
        .newBrowser: "openBrowser",
        .newAgentChat: "palette.newAgentChat",
        .customize: "appearance.customize",
        .searchChats: "agentPane.searchChats",
        .chief: ChiefSidebar.openAction,
        .automations: "automations.show",
    ]

    /// Presentation of every built-in, app and workspace item in `layout` (a closed workspace dimmed); `registered` says
    /// whether an action exists. Notifications carries `unread`, Home (built-in or app) a dot for `homeUnread` (its
    /// unread conversations, ``HomeService/unreadConversations``), the Chief its status (`ChiefSidebar`) and the
    /// picture `chiefFavicon` (its worn upload's, ``ChiefSidebarPictures``), and each
    /// built-in carries its action's `shortcut` for its tooltip. The update
    /// notice is the footer's pill, never an item control (SIDEBAR-FOOTER-MINIMAL). `showsStore` false hides the App Store.
    public static func info(for layout: SidebarLayoutDocument, registered: (ActionID) -> Bool,
                         unread: Int = 0,
                         homeUnread: Int = 0, showsStore: Bool = true,
                         app: (String) -> SidebarItemInfo = { SidebarItemInfo.fallback(for: .app($0)) },
                         shortcut: (ActionID) -> String? = { _ in nil },
                         workspace: (LayoutItemRef) -> SidebarItemInfo? = { _ in nil },
                         chiefFavicon: SidebarFavicon? = nil, listed: [LayoutItem] = []) -> [LayoutItemID: SidebarItemInfo] {
        var infos: [LayoutItemID: SidebarItemInfo] = [:]
        // `listed`: the built-ins the list draws in a group or a machine list, described as the bands' are.
        for item in layout.sections.flatMap(\.items) + listed {
            if item.ref.kind == LayoutItemRef.workspaceKind { infos[item.id] = workspace(item.ref) ?? .closedWorkspace(item); continue }
            if item.ref.kind == LayoutItemRef.appKind {
                var info = app(item.ref.value)
                if SidebarBuiltIn.firstParty(appID: item.ref.value) == .home { ChiefSidebar.shared.decorateHome(&info, homeUnread: homeUnread, picture: chiefFavicon) }
                infos[item.id] = info
                continue
            }
            guard let builtIn = item.ref.builtIn else { continue }
            var info = builtIn.defaultInfo(showsStore: showsStore)
            info.isMissing = !(builtInActions[builtIn].map(registered) ?? false)
            info.shortcut = builtInActions[builtIn].flatMap(shortcut)
            if builtIn == .notifications { info.badge = unread > 0 ? unread : nil } else if builtIn == .home {
                ChiefSidebar.shared.decorateHome(&info, homeUnread: homeUnread, picture: chiefFavicon)
            } else if builtIn == .chief {
                ChiefSidebar.shared.decorate(&info)
                info.favicon = chiefFavicon
            }
            infos[item.id] = info
        }
        return infos
    }
}
