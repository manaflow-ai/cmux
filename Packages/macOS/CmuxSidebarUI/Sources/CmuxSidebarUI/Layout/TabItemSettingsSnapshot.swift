public import CoreGraphics
public import CmuxSettings
public import CmuxSidebar

/// The resolved sidebar-row settings ``TabItemView`` reads. This is the single
/// settings-snapshot value type for the sidebar row: the app target builds it
/// from `UserDefaults`, the setting catalog, and Ghostty config (see the
/// app-side `TabItemSettingsSnapshot` factory) and stores it directly on the
/// row, where `Equatable` keeps it in the row's `==` and `Sendable` lets the
/// generic ``SidebarTabItemSettingsStore`` republish it.
public struct TabItemSettingsSnapshot: Equatable, Sendable {
    public let hidesAllDetails: Bool
    public let wrapsWorkspaceTitles: Bool
    public let showsWorkspaceDescription: Bool
    public let sidebarShortcutHintXOffset: Double
    public let sidebarShortcutHintYOffset: Double
    public let alwaysShowShortcutHints: Bool
    public let sidebarFontScale: CGFloat
    public let showsGitBranch: Bool
    public let usesVerticalBranchLayout: Bool
    public let stacksBranchAndDirectory: Bool
    public let usesLastSegmentPath: Bool
    public let showsGitBranchIcon: Bool
    public let showsSSH: Bool
    public let makesPullRequestsClickable: Bool
    public let openPullRequestLinksInCmuxBrowser: Bool
    public let openPortLinksInCmuxBrowser: Bool
    public let showsNotificationMessage: Bool
    public let activeTabIndicatorStyle: WorkspaceIndicatorStyle
    public let selectionColorHex: String?
    public let notificationBadgeColorHex: String?
    public let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    public let iMessageModeEnabled: Bool

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
