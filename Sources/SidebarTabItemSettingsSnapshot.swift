import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import CoreGraphics
import Foundation

/// Immutable settings projection consumed by both SwiftUI and AppKit sidebar rows.
struct SidebarTabItemSettingsSnapshot: Equatable {
    let hidesAllDetails: Bool
    let wrapsWorkspaceTitles: Bool
    let showsWorkspaceDescription: Bool
    let sidebarShortcutHintXOffset: Double
    let sidebarShortcutHintYOffset: Double
    let alwaysShowShortcutHints: Bool
    let sidebarFontScale: CGFloat
    let showsGitBranch: Bool
    let branchDirectory: SidebarWorkspaceBranchDirectorySettings
    let details: SidebarWorkspaceDetailSettings
    let showsGitBranchIcon: Bool
    let makesPullRequestsClickable: Bool
    let openPullRequestLinksInCmuxBrowser: Bool
    let openPortLinksInCmuxBrowser: Bool
    let showsNotificationMessage: Bool
    let notificationMessageLineLimit: Int
    let activeTabIndicatorStyle: WorkspaceIndicatorStyle
    let loadingSpinnerPosition: SidebarIndicatorPosition
    let notificationBadgePosition: SidebarIndicatorPosition
    let selectionColorHex: String?
    let notificationBadgeColorHex: String?
    let visibleAuxiliaryDetails: SidebarWorkspaceAuxiliaryDetailVisibility
    let iMessageModeEnabled: Bool
    let workspaceTodoChecklistStyle: WorkspaceTodoChecklistStyle

    var usesLastSegmentPath: Bool { branchDirectory.usesLastSegmentPath }
    var showsSSH: Bool { details.showSSH }

    init(
        defaults: UserDefaults = .standard,
        sidebarFontSize: CGFloat = GhosttyConfig.defaultSidebarFontSize
    ) {
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let sidebar = SidebarCatalogSection()
        let workspaceColors = WorkspaceColorsCatalogSection()
        let betaFeatures = BetaFeaturesCatalogSection()
        branchDirectory = SidebarWorkspaceBranchDirectorySettings(defaults: defaults)
        details = SidebarWorkspaceDetailSettings(defaults: defaults)

        sidebarShortcutHintXOffset = ShortcutHintDebugSettings.defaultSidebarHintX
        sidebarShortcutHintYOffset = ShortcutHintDebugSettings.defaultSidebarHintY
        alwaysShowShortcutHints = ShortcutHintDebugSettings(defaults: defaults).alwaysShowHints
        sidebarFontScale = SidebarTabItemFontScale.scale(for: sidebarFontSize)
        showsGitBranch = Self.bool(defaults: defaults, key: "sidebarShowGitBranch", defaultValue: true)
        showsGitBranchIcon = Self.bool(defaults: defaults, key: "sidebarShowGitBranchIcon", defaultValue: false)
        makesPullRequestsClickable = settings.value(for: sidebar.makePullRequestsClickable)
        openPullRequestLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowser(
            defaults: defaults
        )
        openPortLinksInCmuxBrowser = BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowser(
            defaults: defaults
        )
        hidesAllDetails = settings.value(for: sidebar.hideAllDetails)
        wrapsWorkspaceTitles = settings.value(for: sidebar.wrapWorkspaceTitles)
        let detailVisibility = SidebarWorkspaceDetailVisibility(
            showWorkspaceDescription: settings.value(for: sidebar.showWorkspaceDescription),
            showNotificationMessage: settings.value(for: sidebar.showNotificationMessage),
            hideAllDetails: hidesAllDetails
        )
        showsWorkspaceDescription = detailVisibility.showsWorkspaceDescription
        showsNotificationMessage = detailVisibility.showsNotificationMessage
        notificationMessageLineLimit = min(
            max(
                settings.value(for: sidebar.notificationMessageLineLimit),
                SidebarCatalogSection.notificationMessageLineLimitRange.lowerBound
            ),
            SidebarCatalogSection.notificationMessageLineLimitRange.upperBound
        )
        visibleAuxiliaryDetails = SidebarWorkspaceAuxiliaryDetailVisibility.resolved(
            showMetadata: details.showCustomMetadata,
            showLog: details.showLog,
            showProgress: details.showProgress,
            showBranchDirectory: details.showBranchDirectory,
            showPullRequests: details.showPullRequests,
            showPorts: details.showPorts,
            hideAllDetails: hidesAllDetails
        )

        activeTabIndicatorStyle = settings.value(for: workspaceColors.indicatorStyle)
        loadingSpinnerPosition = settings.value(for: sidebar.loadingSpinnerPosition)
        notificationBadgePosition = settings.value(for: sidebar.notificationBadgePosition)
        selectionColorHex = settings.value(for: workspaceColors.selectionColorHex).nilIfEmpty
        notificationBadgeColorHex = settings.value(for: workspaceColors.notificationBadgeColorHex).nilIfEmpty
        iMessageModeEnabled = IMessageModeSettings.isEnabled(defaults: defaults)
        workspaceTodoChecklistStyle = settings.value(for: betaFeatures.workspaceTodosChecklistStyle)
    }

    private static func bool(
        defaults: UserDefaults,
        key: String,
        defaultValue: Bool
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
