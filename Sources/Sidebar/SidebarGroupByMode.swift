import Foundation

/// How one window's workspace sidebar arranges its rows.
///
/// `manual` is the user's own order and workspace groups. The automatic modes
/// only change what the sidebar draws: they never edit `tabs` order or any
/// manual group, so switching back to `manual` restores the exact layout.
enum SidebarGroupByMode: String, Codable, CaseIterable, Sendable {
    /// The user's own order and manual workspace groups.
    case manual
    /// One section per machine: this Mac, each SSH host, each Cloud VM.
    case host
    /// One section per activity state, loudest first.
    case status

    /// Unknown values from a newer build decode as `manual` so an old build can
    /// still restore the rest of the window snapshot.
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .manual
    }

    /// Whether the sidebar shows derived sections instead of manual groups.
    var isAutomatic: Bool { self != .manual }

    /// Menu and palette label for this mode.
    var localizedTitle: String {
        switch self {
        case .manual:
            return String(localized: "sidebar.groupBy.mode.manual", defaultValue: "Manual")
        case .host:
            return String(localized: "sidebar.groupBy.mode.host", defaultValue: "Host")
        case .status:
            return String(localized: "sidebar.groupBy.mode.status", defaultValue: "Status")
        }
    }
}
