import Foundation

/// Which side of a sidebar workspace row a status indicator (the loading
/// spinner or the unread notification badge) appears on. `leading` shares the
/// left status slot before the title; `trailing` sits toward the close-button
/// corner.
public enum SidebarIndicatorPosition: String, CaseIterable, Sendable, SettingCodable {
    /// The left status slot, before the workspace title.
    case leading
    /// The right side of the row, toward the close-button corner.
    case trailing

    /// Maps a stored string onto a position, accepting the friendly `left` /
    /// `right` (and `start`/`end`) aliases used by hand-written cmux.json in
    /// addition to the raw case names. Unknown strings return `nil` so the key
    /// default applies. Mirrors `WorkspaceIndicatorStyle.resolvedLegacy`.
    private static func resolved(_ string: String) -> SidebarIndicatorPosition? {
        if let value = SidebarIndicatorPosition(rawValue: string) {
            return value
        }
        switch string {
        case "left", "start":
            return .leading
        case "right", "end":
            return .trailing
        default:
            return nil
        }
    }

    /// Decodes a UserDefaults value, normalizing the friendly aliases.
    public static func decodeFromUserDefaults(_ raw: Any?) -> SidebarIndicatorPosition? {
        (raw as? String).flatMap(resolved)
    }

    /// Encodes as the raw case name for UserDefaults storage.
    public func encodeForUserDefaults() -> Any { rawValue }

    /// Decodes a cmux.json value, normalizing the friendly aliases.
    public static func decodeFromJSON(_ raw: Any?) -> SidebarIndicatorPosition? {
        (raw as? String).flatMap(resolved)
    }

    /// Encodes as the raw case name for cmux.json storage.
    public func encodeForJSON() -> Any { rawValue }
}
