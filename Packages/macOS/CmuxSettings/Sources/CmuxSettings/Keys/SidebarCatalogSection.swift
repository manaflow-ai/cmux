import Foundation

/// Settings under the dotted-id prefix `sidebar.*` — workspace-row
/// metadata visibility and layout.
public struct SidebarCatalogSection: SettingCatalogSection {
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
    /// every user with a saved preference. `true` means vertical
    /// (branch and directory stacked on their own lines).
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

    /// Built-in hover controls exposed on each sidebar workspace row.
    public let workspaceControls = DefaultsKey<[WorkspaceRowControlOption]>(
        id: "sidebar.workspaceControls",
        defaultValue: WorkspaceRowControlOption.defaultControls,
        userDefaultsKey: "sidebarWorkspaceControls"
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
