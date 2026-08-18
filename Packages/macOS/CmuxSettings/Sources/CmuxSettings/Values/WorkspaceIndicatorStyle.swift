import Foundation

/// Visual style for the active-workspace indicator in the sidebar.
public enum WorkspaceIndicatorStyle: String, CaseIterable, Sendable, SettingCodable {
    case solidFill, leftRail, leftRailAuto

    /// Whether workspace colors render as a narrow leading rail.
    public var usesLeftRail: Bool {
        self != .solidFill
    }

    /// Whether uncolored workspaces receive persisted palette assignments.
    public var automaticallyAssignsWorkspaceColors: Bool {
        self == .leftRailAuto
    }

    /// Resolves the rail color for one workspace, applying the full enablement
    /// rule for this style.
    ///
    /// Returns `nil` — leaving the rail hidden exactly as before the automatic
    /// style existed — whenever this style does not assign colors, the
    /// workspace already carries a manual color, or no color has been assigned.
    ///
    /// An empty `customColorHex` counts as no manual color, matching the
    /// allocator, which also treats it as uncolored and hands the workspace an
    /// automatic color. Disagreeing here would assign a color and then refuse
    /// to draw it.
    public func railColorHex(customColorHex: String?, assignedColorHex: String?) -> String? {
        guard automaticallyAssignsWorkspaceColors,
              customColorHex?.isEmpty != false else {
            return nil
        }
        return assignedColorHex
    }

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
