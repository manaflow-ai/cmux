public import CoreGraphics
public import CmuxSettings

/// Immutable projection of every sidebar tab-item setting consumed by the
/// workspace sidebar row (`VerticalTabsSidebar`/`TabItemView`).
///
/// This is a pure value snapshot: it carries the resolved appearance and
/// behavior flags for one render pass and is only replaced when its fields
/// actually change, so SwiftUI re-renders track real settings transitions
/// rather than `UserDefaults` notification churn. The app owns the
/// `UserDefaults`/`SettingCatalog`-reading construction (an app-side factory
/// builds this memberwise value); this package only defines the value the
/// sidebar reads.
public struct SidebarTabItemSettingsSnapshot: Equatable, Sendable {
    /// Whether the master "hide all auxiliary details" switch is set.
    public let hidesAllDetails: Bool
    /// Whether long workspace titles wrap instead of truncating.
    public let wrapsWorkspaceTitles: Bool
    /// Whether the workspace description line is shown.
    public let showsWorkspaceDescription: Bool
    /// Horizontal offset applied to the per-row shortcut hint badge.
    public let sidebarShortcutHintXOffset: Double
    /// Vertical offset applied to the per-row shortcut hint badge.
    public let sidebarShortcutHintYOffset: Double
    /// Whether shortcut hints are always shown rather than only while a
    /// modifier is held.
    public let alwaysShowShortcutHints: Bool
    /// Font scale derived from the Ghostty sidebar font size.
    public let sidebarFontScale: CGFloat
    /// Whether the git branch is shown on each row.
    public let showsGitBranch: Bool
    /// Whether branch and directory use the stacked vertical layout.
    public let usesVerticalBranchLayout: Bool
    /// Whether branch and directory are stacked rather than inline.
    public let stacksBranchAndDirectory: Bool
    /// Whether only the last path segment of the directory is shown.
    public let usesLastSegmentPath: Bool
    /// Whether the git branch icon is shown.
    public let showsGitBranchIcon: Bool
    /// Whether the SSH indicator is shown.
    public let showsSSH: Bool
    /// Whether pull-request links are rendered as clickable.
    public let makesPullRequestsClickable: Bool
    /// Whether sidebar pull-request links open in the cmux browser.
    public let openPullRequestLinksInCmuxBrowser: Bool
    /// Whether sidebar port links open in the cmux browser.
    public let openPortLinksInCmuxBrowser: Bool
    /// Whether the latest notification message is shown.
    public let showsNotificationMessage: Bool
    /// Indicator style for the active workspace tab.
    public let activeTabIndicatorStyle: WorkspaceIndicatorStyle
    /// Optional custom selection color, as a hex string.
    public let selectionColorHex: String?
    /// Optional custom notification badge color, as a hex string.
    public let notificationBadgeColorHex: String?
    /// Resolved visibility of the auxiliary detail rows under each workspace.
    public let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    /// Whether iMessage mode is enabled.
    public let iMessageModeEnabled: Bool

    /// Creates a snapshot with every resolved field supplied directly.
    public init(
        hidesAllDetails: Bool,
        wrapsWorkspaceTitles: Bool,
        showsWorkspaceDescription: Bool,
        sidebarShortcutHintXOffset: Double,
        sidebarShortcutHintYOffset: Double,
        alwaysShowShortcutHints: Bool,
        sidebarFontScale: CGFloat,
        showsGitBranch: Bool,
        usesVerticalBranchLayout: Bool,
        stacksBranchAndDirectory: Bool,
        usesLastSegmentPath: Bool,
        showsGitBranchIcon: Bool,
        showsSSH: Bool,
        makesPullRequestsClickable: Bool,
        openPullRequestLinksInCmuxBrowser: Bool,
        openPortLinksInCmuxBrowser: Bool,
        showsNotificationMessage: Bool,
        activeTabIndicatorStyle: WorkspaceIndicatorStyle,
        selectionColorHex: String?,
        notificationBadgeColorHex: String?,
        visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility,
        iMessageModeEnabled: Bool
    ) {
        self.hidesAllDetails = hidesAllDetails
        self.wrapsWorkspaceTitles = wrapsWorkspaceTitles
        self.showsWorkspaceDescription = showsWorkspaceDescription
        self.sidebarShortcutHintXOffset = sidebarShortcutHintXOffset
        self.sidebarShortcutHintYOffset = sidebarShortcutHintYOffset
        self.alwaysShowShortcutHints = alwaysShowShortcutHints
        self.sidebarFontScale = sidebarFontScale
        self.showsGitBranch = showsGitBranch
        self.usesVerticalBranchLayout = usesVerticalBranchLayout
        self.stacksBranchAndDirectory = stacksBranchAndDirectory
        self.usesLastSegmentPath = usesLastSegmentPath
        self.showsGitBranchIcon = showsGitBranchIcon
        self.showsSSH = showsSSH
        self.makesPullRequestsClickable = makesPullRequestsClickable
        self.openPullRequestLinksInCmuxBrowser = openPullRequestLinksInCmuxBrowser
        self.openPortLinksInCmuxBrowser = openPortLinksInCmuxBrowser
        self.showsNotificationMessage = showsNotificationMessage
        self.activeTabIndicatorStyle = activeTabIndicatorStyle
        self.selectionColorHex = selectionColorHex
        self.notificationBadgeColorHex = notificationBadgeColorHex
        self.visibleAuxiliaryDetails = visibleAuxiliaryDetails
        self.iMessageModeEnabled = iMessageModeEnabled
    }
}
