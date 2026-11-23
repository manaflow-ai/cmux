// The sidebar profile menu (SIDEBAR-FOOTER-AND-SPACE-MENU amendment 2,
// Lawrence 2026-10-07): the footer's avatar control opens one native menu.
// Every row runs a registry action, so the palette, the CLI and the menu
// share one path. Titles live in ProfileActions.xcstrings; the rows' actions
// are in the Rust catalog (cmux-action-catalog).

/// What the profile menu holds, top to bottom: the current profile (with its
/// options submenu), the submenus, Show Chief, Show Chief Pet, Settings, Check for Updates, the account
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
    /// Show Chief (David Beyer, Nov 20: "Show Chief" did not show the Chief unless he went to Home): opens the
    /// Chief, its conversation or the side panel (`home.openChief`), as the sidebar's Chief row does.
    public var chief: Row
    /// Settings…, under Show Chief Pet: the one settings area. How cmux looks is its Appearance page;
    /// the menu has no second Personalization… row (David Beyer 2026-11-20).
    public var settings: Row
    /// Check for Updates…, under Settings: the app menu has it, and the
    /// profile menu is the sidebar's app menu.
    public var updates: Row
    /// Under Settings: the signed-in accounts and cmux Cloud (PRIORITIES 1.14).
    public var account: [Row]
    public var creation: [Row]

    /// The rows, built in Rust (cmux-action-catalog `status_menus`) in the app's language.
    public init() {
        let reply = RustCatalogCall.reply(["op": "profile_menu", "locale": RustCatalogCall.language]) ?? [:]
        profileActions = Self.ids(reply["profileActions"])
        submenus = (reply["submenus"] as? [[String: Any]] ?? []).map { submenu in
            Submenu(key: submenu["key"] as? String ?? "", title: submenu["title"] as? String ?? "",
                    symbol: submenu["symbol"] as? String ?? "", actions: Self.ids(submenu["actions"]))
        }
        chief = Self.row(reply["chief"])
        settings = Self.row(reply["settings"])
        updates = Self.row(reply["updates"])
        account = (reply["account"] as? [Any] ?? []).map { Self.row($0) }
        creation = (reply["creation"] as? [Any] ?? []).map { Self.row($0) }
    }

    private static func ids(_ node: Any?) -> [ActionID] {
        (node as? [String] ?? []).map { ActionID(rawValue: $0) }
    }

    private static func row(_ node: Any?) -> Row {
        let row = node as? [String: Any] ?? [:]
        return Row(action: ActionID(rawValue: row["action"] as? String ?? ""), title: row["title"] as? String,
                   symbol: row["symbol"] as? String ?? "")
    }

    /// The setting the Show Chief Pet / Hide Chief Pet row flips (CmuxNextSettings `HomeChiefPetSetting`).
    public static let chiefPetSetting = "home.chiefPetEnabled"

    static func text(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, table: "ProfileActions", bundle: .localizedModule)
    }
}
