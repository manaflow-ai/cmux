public import CoreGraphics
public import CmuxSidebar

/// The resolved sidebar-row settings ``TabItemView`` reads, mirrored into a
/// package value type so the lifted row never references the app target's
/// `SidebarTabItemSettingsSnapshot` (whose initializer pulls `UserDefaults`, the
/// setting catalog, and Ghostty config). The app converts its snapshot into this
/// once per parent body eval; `Equatable` keeps it in the row's `==`.
///
/// Indicator-style-derived appearance (border, leading rail, swatch colors) is
/// resolved app-side into ``TabItemRowStyle`` rather than carried here, so this
/// snapshot needs no `CmuxSettings.WorkspaceIndicatorStyle` dependency.
public struct TabItemSettingsSnapshot: Equatable {
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
        self.selectionColorHex = selectionColorHex
        self.notificationBadgeColorHex = notificationBadgeColorHex
        self.visibleAuxiliaryDetails = visibleAuxiliaryDetails
        self.iMessageModeEnabled = iMessageModeEnabled
    }
}
