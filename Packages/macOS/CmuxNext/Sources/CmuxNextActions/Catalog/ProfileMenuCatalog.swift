// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2,
// Lawrence 2026-10-07): the footer's avatar control opens one native menu.
// Every row runs a registry action, so the palette, the CLI and the menu
// share one path. Titles live in ProfileActions.xcstrings.

nonisolated enum ProfileMenuActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            ActionDescriptor(
                id: "sidebar.profileMenu",
                title: ProfileMenuSpec.text("action.sidebar.profileMenu", "Show Profile Menu"),
                keywords: ["profile", "account", "avatar", "menu", "bookmarks", "downloads", "extensions", "history", "developer"],
                category: .sidebar, symbol: "person.crop.circle", surfaces: [.palette, .keyboard],
                cliName: "sidebar profile-menu"
            ),
            ActionDescriptor(
                id: "browser.downloads.showFolder",
                title: ProfileMenuSpec.text("action.browser.downloads.showFolder", "Open Downloads Folder"),
                keywords: ["downloads", "files", "finder", "browser"],
                category: .browser, symbol: "arrow.down.to.line", surfaces: [.palette, .keyboard],
                cliName: "browser downloads-folder"
            ),
        ]
    }
}

/// What the profile menu holds, top to bottom: the current profile (with its
/// options submenu), the submenus, Settings, Check for Updates, the account
/// rows (Accounts…, Cloud), then New Tab and Incognito Window. A submenu row or action the build
/// does not register is left out, and a submenu with no row is left out
/// (items whose feature does not exist are omitted, not disabled). "New
/// profile" is hidden until the profiles lane exists.
public nonisolated struct ProfileMenuSpec: Sendable {
    /// One "Bookmarks >"-style row.
    public struct Submenu: Sendable, Hashable {
        public var key: String
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

    public var profileActions: [ActionID]
    public var submenus: [Submenu]
    public var settings: Row
    /// Check for Updates…, under Settings: the app menu has it, and the
    /// profile menu is the sidebar's app menu.
    public var updates: Row
    /// Under Settings: the signed-in accounts and cmux Cloud (PRIORITIES 1.14).
    public var account: [Row]
    public var creation: [Row]

    public init() {
        // The current profile's submenu: its own options (real switching and
        // creating come with the profiles lane).
        profileActions = ["browserProfile.rename", "browserProfile.setColor", "browserProfile.setIcon", "browserProfile.manageExtensions"]
        submenus = [
            Submenu(key: "bookmarks", title: Self.text("menu.profile.bookmarks", "Bookmarks"), symbol: "bookmark",
                    actions: ["bookmark.addPage", "bookmark.addAllTabs", "bookmark.toggleBar", "bookmark.manager", "bookmark.import"]),
            Submenu(key: "downloads", title: Self.text("menu.profile.downloads", "Downloads"), symbol: "arrow.down.to.line",
                    actions: ["browser.downloads.showFolder"]),
            Submenu(key: "extensions", title: Self.text("menu.profile.extensions", "Extensions"), symbol: "puzzlepiece",
                    actions: ["browser.extensions.manage", "browser.extensions.webStore", "browser.extensions.loadUnpacked"]),
            Submenu(key: "history", title: Self.text("menu.profile.history", "History"), symbol: "clock.arrow.circlepath",
                    actions: ["history.show", "recentlyClosed", "history.reopen", "history.clear"]),
            Submenu(key: "developers", title: Self.text("menu.profile.developers", "Developers"),
                    symbol: "chevron.left.forwardslash.chevron.right",
                    actions: ["toggleBrowserDeveloperTools", "showBrowserJavaScriptConsole", "inspectBrowserElement"]),
        ]
        settings = Row(action: "openSettings", title: nil, symbol: "gear")
        updates = Row(action: "palette.checkForUpdates", title: nil, symbol: "arrow.down.circle")
        account = [
            Row(action: "accounts.show", title: nil, symbol: "person.crop.circle"),
            Row(action: "palette.openCloudPane", title: Self.text("menu.profile.cloud", "Cloud"), symbol: "cloud"),
        ]
        creation = [
            Row(action: "newTab.default", title: nil, symbol: "plus"),
            Row(action: "newIncognitoWindow", title: Self.text("menu.profile.incognito", "Incognito Window"), symbol: "eyeglasses"),
        ]
    }

    /// The setting the Show Chief / Hide Chief row flips (CmuxNextSettings `HomeChiefPetSetting`).
    public static let chiefPetSetting = "home.chiefPetEnabled"

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .module)
    }
}
