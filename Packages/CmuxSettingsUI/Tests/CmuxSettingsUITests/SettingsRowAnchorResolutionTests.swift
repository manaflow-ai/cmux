import CmuxSettings
import Testing
@testable import CmuxSettingsUI

/// Guards the search-result highlight bridge: every cmux.json path that a
/// `SettingsCardRow` declares via `configurationReview` must resolve,
/// through ``SettingsSearchIndex/anchorID(forSettingsPath:)``, to a real
/// indexed entry. Otherwise clicking that row's search hit scrolls and
/// pulses nothing (the bug that hit "Sidebar Branch Layout", whose row
/// path `sidebar.branchLayout` didn't match the curated synonym's
/// `sidebar.branchVerticalLayout`).
///
/// The list mirrors the `.json(...)` annotations in `Sections/*.swift`.
/// When a new settings row is added, add its path here so the bridge is
/// proven before the row ships.
@Suite("SettingsRowAnchorResolution")
struct SettingsRowAnchorResolutionTests {
    /// Every dotted cmux.json path declared by a settings row.
    static let rowConfigPaths: [String] = [
        "app.commandPaletteSearchesAllSurfaces",
        "app.focusPaneOnFirstClick",
        "app.hideTabCloseButton",
        "app.iMessageMode",
        "app.keepWorkspaceOpenWhenClosingLastSurface",
        "app.language",
        "app.menuBarOnly",
        "app.minimalMode",
        "app.newWorkspacePlacement",
        "app.openMarkdownInCmuxViewer",
        "app.openSupportedFilesInCmux",
        "app.preferredEditor",
        "app.renameSelectsExistingName",
        "app.reorderOnNotification",
        "app.sendAnonymousTelemetry",
        "app.warnBeforeClosingTab",
        "app.warnBeforeClosingTabXButton",
        "app.workspaceInheritWorkingDirectory",
        "automation.claudeBinaryPath",
        "automation.claudeCodeIntegration",
        "automation.cursorIntegration",
        "automation.geminiIntegration",
        "automation.portBase",
        "automation.portRange",
        "automation.ripgrepBinaryPath",
        "automation.socketControlMode",
        "automation.socketPassword",
        "automation.suppressSubagentNotifications",
        "browser.customSearchEngineName",
        "browser.customSearchEngineURLTemplate",
        "browser.defaultSearchEngine",
        "browser.discardHiddenWebViews",
        "browser.hiddenWebViewDiscardDelaySeconds",
        "browser.interceptTerminalOpenCommandInCmuxBrowser",
        "browser.openTerminalLinksInCmuxBrowser",
        "browser.reactGrabVersion",
        "browser.showSearchSuggestions",
        "browser.theme",
        "notifications.command",
        "notifications.dockBadge",
        "notifications.paneFlash",
        "notifications.showInMenuBar",
        "notifications.unreadPaneRing",
        "sidebar.branchLayout",
        "sidebar.hideAllDetails",
        "sidebar.makePullRequestsClickable",
        "sidebar.openPortLinksInCmuxBrowser",
        "sidebar.openPullRequestLinksInCmuxBrowser",
        "sidebar.pathLastSegmentOnly",
        "sidebar.showBranchDirectory",
        "sidebar.showCustomMetadata",
        "sidebar.showLog",
        "sidebar.showNotificationMessage",
        "sidebar.showPorts",
        "sidebar.showProgress",
        "sidebar.showPullRequests",
        "sidebar.showSSH",
        "sidebar.showWorkspaceDescription",
        "sidebar.stackBranchDirectory",
        "sidebar.watchGitStatus",
        "sidebar.wrapWorkspaceTitles",
        "sidebarAppearance.matchTerminalBackground",
        "terminal.agentHibernation.enabled",
        "terminal.agentHibernation.idleSeconds",
        "terminal.agentHibernation.maxLiveTerminals",
        "terminal.autoResumeAgentSessions",
        "terminal.copyOnSelect",
        "terminal.resumeCommands",
        "terminal.showScrollBar",
        "terminal.textBoxMaxLines",
        "workspaceColors.colors",
        "workspaceColors.indicatorStyle",
    ]

    @Test(arguments: rowConfigPaths)
    func everyRowPathResolvesToAnIndexedEntry(path: String) throws {
        let index = SettingsSearchIndex(catalog: SettingCatalog())
        let anchor = try #require(
            index.anchorID(forSettingsPath: path),
            "no anchor for row path \(path) — its search hit won't scroll/highlight"
        )
        #expect(
            index.entries.contains { $0.id == anchor },
            "anchor \(anchor) for \(path) is not a real indexed entry"
        )
    }
}
