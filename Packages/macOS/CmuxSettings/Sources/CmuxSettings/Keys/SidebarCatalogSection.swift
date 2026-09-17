import Foundation

/// Settings under the dotted-id prefix `sidebar.*` — workspace-row
/// metadata visibility and layout.
public struct SidebarCatalogSection: SettingCatalogSection {
    /// Valid notification-preview line limits for settings UI and configuration parsing.
    public static let notificationMessageLineLimitRange = 1...50

    /// Resolves the shipped legacy layout contract together with the newer
    /// branch/directory placement preference.
    public static func stacksBranchAndDirectory(
        vertical: Bool,
        explicit: Bool
    ) -> Bool {
        vertical || explicit
    }

    public let hideAllDetails = DefaultsKey<Bool>(
        id: "sidebar.hideAllDetails",
        defaultValue: false,
        userDefaultsKey: "sidebarHideAllDetails"
    )

    public let wrapWorkspaceTitles = DefaultsKey<Bool>(
        id: "sidebar.wrapWorkspaceTitles",
        defaultValue: false,
        userDefaultsKey: "sidebarWrapWorkspaceTitles"
    )

    public let showWorkspaceDescription = DefaultsKey<Bool>(
        id: "sidebar.showWorkspaceDescription",
        defaultValue: true,
        userDefaultsKey: "sidebarShowWorkspaceDescription"
    )

    /// Bool-backed to match the legacy in-app store. The on-disk key
    /// `sidebarBranchVerticalLayout` is written as a Bool by every
    /// shipped cmux build; using an enum here would silently revert
    /// every user with a saved preference. `true` preserves the legacy
    /// vertical presentation: each panel's branch/directory record gets its
    /// own row, with branch and directory on separate subrows. When this is
    /// `false`, `stackBranchDirectory` can still opt the compact branch layout
    /// into separate branch and directory subrows.
    public let branchVerticalLayout = DefaultsKey<Bool>(
        id: "sidebar.branchVerticalLayout",
        defaultValue: true,
        userDefaultsKey: "sidebarBranchVerticalLayout"
    )

    public let stackBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.stackBranchDirectory",
        defaultValue: false,
        userDefaultsKey: "sidebarBranchDirectoryStacked"
    )

    public let pathLastSegmentOnly = DefaultsKey<Bool>(
        id: "sidebar.pathLastSegmentOnly",
        defaultValue: false,
        userDefaultsKey: "sidebarPathLastSegmentOnly"
    )

    public let showNotificationMessage = DefaultsKey<Bool>(
        id: "sidebar.showNotificationMessage",
        defaultValue: true,
        userDefaultsKey: "sidebarShowNotificationMessage"
    )

    /// Maximum notification-preview lines shown per workspace, defaulting to 12.
    public let notificationMessageLineLimit = DefaultsKey<Int>(
        id: "sidebar.notificationMessageLineLimit",
        defaultValue: 12,
        userDefaultsKey: "sidebarNotificationMessageLineLimit"
    )

    public let showBranchDirectory = DefaultsKey<Bool>(
        id: "sidebar.showBranchDirectory",
        defaultValue: true,
        userDefaultsKey: "sidebarShowBranchDirectory"
    )

    public let showPullRequests = DefaultsKey<Bool>(
        id: "sidebar.showPullRequests",
        defaultValue: true,
        userDefaultsKey: "sidebarShowPullRequest"
    )

    public let watchGitStatus = DefaultsKey<Bool>(
        id: "sidebar.watchGitStatus",
        defaultValue: true,
        userDefaultsKey: "sidebarWatchGitStatus"
    )

    public let makePullRequestsClickable = DefaultsKey<Bool>(
        id: "sidebar.makePullRequestsClickable",
        defaultValue: true,
        userDefaultsKey: "sidebarMakePullRequestClickable"
    )

    public let openPullRequestLinksInCmuxBrowser = DefaultsKey<Bool>(
        id: "sidebar.openPullRequestLinksInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    )

    public let openPortLinksInCmuxBrowser = DefaultsKey<Bool>(
        id: "sidebar.openPortLinksInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenSidebarPortLinksInCmuxBrowser"
    )

    public let showSSH = DefaultsKey<Bool>(
        id: "sidebar.showSSH",
        defaultValue: true,
        userDefaultsKey: "sidebarShowSSH"
    )

    public let showPorts = DefaultsKey<Bool>(
        id: "sidebar.showPorts",
        defaultValue: true,
        userDefaultsKey: "sidebarShowPorts"
    )

    public let showLog = DefaultsKey<Bool>(
        id: "sidebar.showLog",
        defaultValue: true,
        userDefaultsKey: "sidebarShowLog"
    )

    public let showProgress = DefaultsKey<Bool>(
        id: "sidebar.showProgress",
        defaultValue: true,
        userDefaultsKey: "sidebarShowProgress"
    )

    /// Whether sidebar workspace rows show the loading spinner for running
    /// coding agents and manual `cmux workspace loading` loaders
    /// (`sidebar.showAgentActivity`). Defaults to on.
    public let showAgentActivity = DefaultsKey<Bool>(
        id: "sidebar.showAgentActivity",
        defaultValue: true,
        userDefaultsKey: "sidebarShowAgentActivity"
    )

    /// Which side of the workspace row the loading spinner appears on
    /// (`sidebar.loadingSpinnerPosition`). Defaults to leading (left), sharing
    /// the unread-badge slot.
    public let loadingSpinnerPosition = DefaultsKey<SidebarIndicatorPosition>(
        id: "sidebar.loadingSpinnerPosition",
        defaultValue: .leading,
        userDefaultsKey: "sidebarLoadingSpinnerPosition"
    )

    /// Which side of the workspace row the unread notification badge appears on
    /// (`sidebar.notificationBadgePosition`). Defaults to leading (left).
    public let notificationBadgePosition = DefaultsKey<SidebarIndicatorPosition>(
        id: "sidebar.notificationBadgePosition",
        defaultValue: .leading,
        userDefaultsKey: "sidebarNotificationBadgePosition"
    )

    public let showCustomMetadata = DefaultsKey<Bool>(
        id: "sidebar.showCustomMetadata",
        defaultValue: true,
        userDefaultsKey: "sidebarShowStatusPills"
    )

    public let rightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth",
        defaultValue: RightSidebarWidthSettings.noOverrideValue,
        userDefaultsKey: RightSidebarWidthSettings.maxWidthKey
    )

    public let rememberedRightMaxWidth = DefaultsKey<Double>(
        id: "sidebar.rightMaxWidth.remembered",
        defaultValue: RightSidebarWidthSettings.defaultConfiguredMaximumWidth,
        userDefaultsKey: RightSidebarWidthSettings.rememberedMaxWidthKey
    )

    public let activeTabIndicatorStyle = DefaultsKey<String>(
        id: "sidebar.activeTabIndicatorStyle",
        defaultValue: "leftRail",
        userDefaultsKey: "sidebarActiveTabIndicatorStyle"
    )

    public let selectionColorHex = DefaultsKey<String>(
        id: "sidebar.selectionColor",
        defaultValue: "",
        userDefaultsKey: "sidebarSelectionColorHex"
    )

    public let notificationBadgeColorHex = DefaultsKey<String>(
        id: "sidebar.notificationBadgeColor",
        defaultValue: "",
        userDefaultsKey: "sidebarNotificationBadgeColorHex"
    )

    public init() {}
}
