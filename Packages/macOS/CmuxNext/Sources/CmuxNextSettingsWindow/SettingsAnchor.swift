public import CmuxNextActions
public import CmuxNextSettings

/// A place on a Settings page that search and deep links scroll to: a
/// schema row, a custom card, an action button or a section header. `id` is
/// the view's scroll id (`.id(_:)`), unique across every section, so the
/// one-page layout can hold every anchor at once.
public struct SettingsAnchor: Hashable, Sendable {
    public let section: SettingsSection
    public let id: String

    public init(section: SettingsSection, id: String) {
        self.section = section
        self.id = id
    }

    /// A schema row; its id is the cmux-next.json key (`tabs.newTabKind`).
    public static func setting(_ descriptor: SettingDescriptor) -> SettingsAnchor {
        SettingsAnchor(section: descriptor.section, id: descriptor.id)
    }

    public static func card(_ card: SettingsCardID) -> SettingsAnchor {
        SettingsAnchor(section: card.section, id: card.anchorID)
    }

    /// An action button of `section` (the same action can sit on two pages).
    public static func action(_ action: ActionID, in section: SettingsSection) -> SettingsAnchor {
        SettingsAnchor(section: section, id: "action.\(section.rawValue).\(action.rawValue)")
    }

    /// The section's header on the one page.
    public static func header(_ section: SettingsSection) -> SettingsAnchor {
        SettingsAnchor(section: section, id: "section.\(section.rawValue)")
    }

    public var isHeader: Bool { id == Self.header(section).id }
}

/// A request to scroll to an anchor. `serial` changes on every request, so
/// opening the same row twice scrolls and highlights it again.
public struct SettingsJump: Hashable, Sendable {
    public let anchor: SettingsAnchor
    public let serial: Int
    /// Rows found by search or a deep link light up; a sidebar click on the
    /// one page only scrolls.
    public let highlights: Bool
}

/// The custom cards search indexes beside the schema rows.
public enum SettingsCardID: String, CaseIterable, Sendable {
    case theme, terminal, accounts, rooms, browserProfiles, machines, advanced

    public var anchorID: String { "card.\(rawValue)" }

    public var section: SettingsSection {
        switch self {
        case .theme: .appearance
        case .terminal: .terminal
        case .accounts: .accounts
        case .rooms, .browserProfiles: .rooms
        case .machines: .machines
        case .advanced: .advanced
        }
    }

    var title: String {
        switch self {
        case .theme: SettingsWindowStrings.themePickerTitle
        case .terminal: SettingsWindowStrings.ghosttyConfig
        case .accounts: SettingsSection.accounts.title
        case .rooms: SettingsSection.rooms.title
        case .browserProfiles: SettingsWindowStrings.browserProfilesTitle
        case .machines: SettingsSection.machines.title
        case .advanced: SettingsWindowStrings.settingsFile
        }
    }

    /// Words search matches besides the title and the section's title
    /// (English, like the schema's keywords).
    var keywords: [String] {
        switch self {
        case .theme: ["theme", "themes", "colors", "colours", "color scheme", "ghostty", "space theme", "room theme", "workspace theme", "terminal theme"]
        case .terminal: ["ghostty", "config", "font", "cursor", "keybinds", "shell integration", "shell"]
        case .accounts: ["accounts", "sign in", "login", "provider", "coderouter", "claude", "codex"]
        case .rooms: ["spaces", "space", "rooms", "room", "profiles"]
        case .browserProfiles: ["browser", "profiles", "profile", "cookies", "logins", "new profile", "extensions"]
        case .machines: ["machines", "ssh", "cloud", "remote", "devbox", "server"]
        case .advanced: ["advanced", "cmux-next.json", "settings file", "show in finder", "reset all", "problems", "diagnostics"]
        }
    }
}
