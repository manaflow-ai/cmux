import Foundation

/// How much secondary detail workspace rows show in the left sidebar
/// (`sidebar.density`).
///
/// A density only supplies defaults. A detail setting the user set explicitly,
/// in Settings, the command palette, or `cmux.json`, keeps its own value. The
/// `sidebar.hideAllDetails` switch still hides every detail regardless of
/// density.
public enum SidebarDensity: String, CaseIterable, Sendable, SettingCodable {
    /// Every detail is shown, matching the individual settings' own defaults.
    case full
    /// Hides the latest log line and keeps notification previews to two lines.
    case compact
    /// Shows the title row plus attention signals (unread badge, agent
    /// activity) and hides the other details.
    case quiet

    /// The value this density gives a sidebar detail toggle, or `nil` when the
    /// toggle keeps its catalog default.
    ///
    /// - Parameter settingID: A dotted setting id such as `sidebar.showPorts`.
    public func presetValue(forSettingID settingID: String) -> Bool? {
        switch self {
        case .full:
            return nil
        case .compact:
            return settingID == "sidebar.showLog" ? false : nil
        case .quiet:
            return Self.quietHiddenSettingIDs.contains(settingID) ? false : nil
        }
    }

    /// The notification preview line limit this density supplies, or `nil` to
    /// keep the catalog default.
    public var notificationMessageLineLimit: Int? {
        switch self {
        case .full, .quiet:
            return nil
        case .compact:
            return 2
        }
    }

    /// The detail toggles whose effective value depends on the density.
    public static let governedSettingIDs: Set<String> = quietHiddenSettingIDs

    private static let quietHiddenSettingIDs: Set<String> = [
        "sidebar.showWorkspaceDescription",
        "sidebar.showNotificationMessage",
        "sidebar.showBranchDirectory",
        "sidebar.showPullRequests",
        "sidebar.showPorts",
        "sidebar.showLog",
        "sidebar.showProgress",
        "sidebar.showCustomMetadata",
    ]
}
