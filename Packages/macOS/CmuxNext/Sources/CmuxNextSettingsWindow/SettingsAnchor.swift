public import CmuxNextActions
public import CmuxNextSettings
import Foundation

/// A place in Settings that a deep link opens (`openSettings setting:`): a schema row, a custom
/// card, an action button or a section header. The React page opens its section, and a schema
/// row is also focused (`#/settings/<section>?focus=<key>`).
public struct SettingsAnchor: Hashable, Sendable {
    public let section: SettingsSection
    public let id: String

    public init(section: SettingsSection, id: String) {
        self.section = section
        self.id = id
    }

    /// A schema row; its id is the cmux.json key (`tabs.newTabPosition`).
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

    /// The section's header.
    public static func header(_ section: SettingsSection) -> SettingsAnchor {
        SettingsAnchor(section: section, id: "section.\(section.rawValue)")
    }

    public var isHeader: Bool { id == Self.header(section).id }

    /// The anchor `key` names (the deep link `openSettings setting:`): a
    /// cmux.json key path (`tabs.newTabPosition`), a card (`theme` or
    /// `card.theme`), a section header (`section.keyboard`), or an action
    /// button (`importFromBrowser`, or its anchor id). Nil when Settings
    /// shows no such thing.
    public init?(key: String) {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let path = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let descriptor = SettingsSchema.descriptor(for: path), descriptor.isShownOnSettingsPage {
            self = .setting(descriptor)
            return
        }
        if let card = SettingsCardID.allCases.first(where: { $0.anchorID == key || $0.rawValue == key }) {
            self = .card(card)
            return
        }
        for section in SettingsSection.allCases {
            if key == SettingsAnchor.header(section).id {
                self = .header(section)
                return
            }
            for action in SettingsSchema.actions(in: section)
            where key == action.rawValue || key == SettingsAnchor.action(action, in: section).id {
                self = .action(action, in: section)
                return
            }
        }
        return nil
    }
}

/// The custom parts of a section that a deep link can name beside the schema rows (the page draws
/// them from the host lists).
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
}

/// A place on a page-only category, one no schema section draws: Settings > Devices' join consent
/// switches (`devices.join.control`), which the page draws from the host's lists (`devices_join`)
/// while this Mac is joined to a team. A deep link (`openSettings setting:devices.join.control`, the
/// consent sheet's Settings…) opens its route, and the page reveals the row
/// (`data-devices-join-consent="control"`): scrolled to and its switch focused. Settings search finds
/// the same rows by their titles and the host's search words (webviews settings `search.ts`).
public enum SettingsPageAnchor: String, CaseIterable, Sendable {
    case joinScreen = "devices.join.screen"
    case joinControl = "devices.join.control"
    case joinSignedInMachines = "devices.join.signedInMachines"

    /// The page category that draws it (not a ``SettingsSection``: Devices has no schema rows).
    public var category: String { "devices" }

    /// The page route that opens on it.
    public var route: String { "#/settings/\(category)?focus=\(rawValue)" }

    /// The anchor of a join consent switch, by its surface (`screen`, `control`, `signedInMachines`).
    public static func joinConsent(_ surface: String) -> SettingsPageAnchor? {
        SettingsPageAnchor(rawValue: "devices.join.\(surface)")
    }

    /// The anchor `key` names (trimmed); nil for any other name.
    public init?(key: String) {
        self.init(rawValue: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
