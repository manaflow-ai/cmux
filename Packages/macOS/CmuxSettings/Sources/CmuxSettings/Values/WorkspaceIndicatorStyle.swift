import Foundation

/// Visual style for the active-workspace indicator in the sidebar.
public enum WorkspaceIndicatorStyle: String, CaseIterable, Sendable, SettingCodable {
    case leftRail, solidFill

    /// Maps raw strings written by earlier iterations of the indicator
    /// setting onto the closest modern case, exactly as the legacy
    /// `SidebarActiveTabIndicatorSettings.resolvedStyle` did. Unknown
    /// strings return `nil` so the key default applies.
    private static func resolvedLegacy(_ string: String) -> WorkspaceIndicatorStyle? {
        if let style = WorkspaceIndicatorStyle(rawValue: string) {
            return style
        }
        switch string {
        case "rail":
            return .leftRail
        case "border", "wash", "lift", "typography", "washRail", "blueWashColorRail":
            return .solidFill
        default:
            return nil
        }
    }

    public static func decodeFromUserDefaults(_ raw: Any?) -> WorkspaceIndicatorStyle? {
        (raw as? String).flatMap(resolvedLegacy)
    }

    public func encodeForUserDefaults() -> Any { rawValue }

    /// The `settings.json` path normalized legacy strings through the same
    /// mapping before storing, so JSON decode accepts them too.
    public static func decodeFromJSON(_ raw: Any?) -> WorkspaceIndicatorStyle? {
        (raw as? String).flatMap(resolvedLegacy)
    }

    public func encodeForJSON() -> Any { rawValue }
}
