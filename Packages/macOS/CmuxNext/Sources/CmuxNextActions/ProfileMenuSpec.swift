// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2,
// Lawrence 2026-10-07): the footer's avatar control opens one menu, drawn on
// cmux's glass. Every row runs a registry action, so the palette, the CLI and
// the menu share one path. Titles live in ProfileActions.xcstrings; the rows'
// actions are in the Rust catalog (cmux-action-catalog).

/// What the profile menu holds, laid out as the Codex app's account menu (Lawrence 2026-11-23: "like this menu is
/// ugly as well; we need better menu design. potentially let's just match these screenshots"): one account row
/// whose chevron opens the teams and Accounts…, New Workspace and New Window with their shortcuts, a short list of
/// rows with icons (Extensions ›, History ›, Cloud, Settings…, Check for Updates…), then Help and Sign Out. A row or
/// action the build does not register is left out, and a submenu with no row is left out (items whose feature does
/// not exist are omitted, not disabled).
///
/// Lawrence, 2026-11-24, of the first Codex-style menu: "show chief/show chief pet is not useful. fix. we should
/// have new workspace and new window shortcuts still. should show extensions and history still. new window good
/// too." The sidebar's Chief row and the View menu show the Chief and its pet. Bookmarks, Downloads, Developers,
/// New Tab and Incognito Window stay out: the browser's More (⋮) menu and the File menu have them. The menu before
/// the Codex one (Leo and Lawrence, 2026-10-07 to 2026-11-20) listed every team as a row of its own: 22 rows.
public nonisolated struct ProfileMenuSpec: Sendable {
    /// One "Extensions ›"-style row: its title, its symbol and the actions its submenu runs.
    public struct Submenu: Sendable, Hashable {
        public var title: String
        public var symbol: String
        public var actions: [ActionID]
    }

    /// One plain row: an action, its menu-only title (nil keeps the
    /// action's own) and its symbol.
    public struct Row: Sendable, Hashable {
        public var action: ActionID
        public var title: String?
        public var symbol: String
    }

    /// The signed-out profile row's submenu: the current browser profile's options.
    public var profileActions: [ActionID]
    /// New Workspace (⌘N) and New Window (⇧⌘N), under the account row: the File menu's own actions, their
    /// shortcuts shown.
    public var creation: [Row]
    /// Extensions › and History ›, above Cloud: the browser's rows for each.
    public var submenus: [Submenu]
    /// cmux Cloud, under History (PRIORITIES 1.14).
    public var cloud: Row
    /// Settings…, under Cloud: the one settings area. How cmux looks is its Appearance page;
    /// the menu has no second Personalization… row (David Beyer 2026-11-20).
    public var settings: Row
    /// Check for Updates…, under Settings (Austin 2026-10-20): the app menu has it, and the
    /// profile menu is the sidebar's app menu.
    public var updates: Row
    /// Accounts…: the last row of the account row's submenu, under the teams.
    public var accounts: Row
    /// Help ›, above Sign Out: the Help menu's own rows.
    public var help: [ActionID]

    public init() {
        // The current profile's submenu: its own options (real switching and
        // creating come with the profiles lane).
        profileActions = ["browserProfile.rename", "browserProfile.setColor", "browserProfile.setIcon", "browserProfile.manageExtensions"]
        creation = [
            Row(action: "newTab", title: nil, symbol: "plus"),
            Row(action: "newWindow", title: nil, symbol: "macwindow"),
        ]
        submenus = [
            Submenu(title: Self.text("menu.profile.extensions", "Extensions"), symbol: "puzzlepiece",
                    actions: ["browser.extensions.manage", "browser.extensions.webStore", "browser.extensions.loadUnpacked"]),
            Submenu(title: Self.text("menu.profile.history", "History"), symbol: "clock.arrow.circlepath",
                    actions: ["history.show", "recentlyClosed", "history.reopen", "history.clear"]),
        ]
        cloud = Row(action: "palette.openCloudPane", title: Self.text("menu.profile.cloud", "Cloud"), symbol: "cloud")
        settings = Row(action: "openSettings", title: nil, symbol: "gear")
        updates = Row(action: "palette.checkForUpdates", title: nil, symbol: "arrow.down.circle")
        accounts = Row(action: "accounts.show", title: nil, symbol: "person.crop.circle")
        help = ["help.documentation", "palette.searchShortcuts", "updates.whatsNew", "sendFeedback"]
    }

    /// The Help row's title and symbol.
    public static var helpTitle: String { text("menu.profile.help", "Help") }
    public static let helpSymbol = "questionmark.circle"

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .localizedModule)
    }
}
