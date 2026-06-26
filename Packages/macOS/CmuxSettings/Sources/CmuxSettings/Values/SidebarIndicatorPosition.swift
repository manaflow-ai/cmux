import Foundation

/// Which side of a sidebar workspace row the loading spinner appears on.
/// `leading` shares the unread-badge slot (the two cross-fade into each other);
/// `trailing` sits in the close-button corner.
public enum SidebarIndicatorPosition: String, CaseIterable, Sendable, SettingCodable {
    case leading, trailing

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

    public static func decodeFromUserDefaults(_ raw: Any?) -> SidebarIndicatorPosition? {
        (raw as? String).flatMap(resolved)
    }

    public func encodeForUserDefaults() -> Any { rawValue }

    public static func decodeFromJSON(_ raw: Any?) -> SidebarIndicatorPosition? {
        (raw as? String).flatMap(resolved)
    }

    public func encodeForJSON() -> Any { rawValue }
}
