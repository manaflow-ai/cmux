// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2,
// Lawrence 2026-10-07): the footer's avatar control opens one menu, drawn on
// cmux's glass. Every row runs a registry action, so the palette, the CLI and
// the menu share one path. Titles live in ProfileActions.xcstrings; the rows'
// actions are in the Rust catalog (cmux-action-catalog).

/// What the profile menu holds, laid out as the Codex app's account menu (Lawrence 2026-11-23: "like this menu is
/// ugly as well; we need better menu design. potentially let's just match these screenshots"): one account row
/// whose chevron opens the teams and Accounts…, a short list of rows with icons (Show Chief, Show Chief Pet, Cloud,
/// Settings…, Check for Updates…), then Help and Sign Out. A row or action the build does not register is left out,
/// and a submenu with no row is left out (items whose feature does not exist are omitted, not disabled).
///
/// The browser's rows (Bookmarks, Downloads, Extensions, History, Developers, New Tab, Incognito Window) are not
/// in it: the browser's More (⋮) menu owns them, and the File menu, the + button and their shortcuts open tabs and
/// windows. The menu before this one (Leo and Lawrence, 2026-10-07 to 2026-11-20) listed every team as a row of its
/// own and those browser submenus at the top level: 22 rows.
public nonisolated struct ProfileMenuSpec: Sendable {
    /// One plain row: an action, its menu-only title (nil keeps the
    /// action's own) and its symbol.
    public struct Row: Sendable, Hashable {
        public var action: ActionID
        public var title: String?
        public var symbol: String
    }

    /// The signed-out profile row's submenu: the current browser profile's options.
    public var profileActions: [ActionID]
    /// Show Chief (David Beyer, Nov 20: "Show Chief" did not show the Chief unless he went to Home): opens the
    /// Chief, its conversation or the side panel (`home.openChief`), as the sidebar's Chief row does.
    public var chief: Row
    /// cmux Cloud, under Show Chief Pet (PRIORITIES 1.14).
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
        chief = Row(action: "home.openChief", title: Self.text("menu.profile.showChief", "Show Chief"), symbol: "sparkles")
        cloud = Row(action: "palette.openCloudPane", title: Self.text("menu.profile.cloud", "Cloud"), symbol: "cloud")
        settings = Row(action: "openSettings", title: nil, symbol: "gear")
        updates = Row(action: "palette.checkForUpdates", title: nil, symbol: "arrow.down.circle")
        accounts = Row(action: "accounts.show", title: nil, symbol: "person.crop.circle")
        help = ["help.documentation", "palette.searchShortcuts", "updates.whatsNew", "sendFeedback"]
    }

    /// The Help row's title and symbol.
    public static var helpTitle: String { text("menu.profile.help", "Help") }
    public static let helpSymbol = "questionmark.circle"

    /// The setting the Show Chief Pet / Hide Chief Pet row flips (CmuxNextSettings `HomeChiefPetSetting`).
    public static let chiefPetSetting = "home.chiefPetEnabled"

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .localizedModule)
    }
}
