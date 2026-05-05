extension CmuxSettingsFileStore {
    static let userDefaultWriteBackTargets: [String: ManagedSettingsWriteBackTarget] = [
        LanguageSettings.languageKey: .string("app.language"),
        AppearanceSettings.appearanceModeKey: .string("app.appearance"),
        AppIconSettings.modeKey: .string("app.appIcon"),
        MenuBarOnlySettings.menuBarOnlyKey: .bool("app.menuBarOnly"),
        WorkspacePlacementSettings.placementKey: .string("app.newWorkspacePlacement"),
        WorkspacePresentationModeSettings.modeKey: .string(
            "app.minimalMode",
            writeBack: .minimalPresentationMode
        ),
        LastSurfaceCloseShortcutSettings.key: .bool(
            "app.keepWorkspaceOpenWhenClosingLastSurface",
            writeBack: .invertedBool
        ),
        PaneFirstClickFocusSettings.enabledKey: .bool("app.focusPaneOnFirstClick"),
        PreferredEditorSettings.key: .string("app.preferredEditor"),
        CmdClickMarkdownRouteSettings.key: .bool("app.openMarkdownInCmuxViewer"),
        WorkspaceAutoReorderSettings.key: .bool("app.reorderOnNotification"),
        IMessageModeSettings.key: .bool("app.iMessageMode"),
        TelemetrySettings.sendAnonymousTelemetryKey: .bool("app.sendAnonymousTelemetry"),
        QuitWarningSettings.warnBeforeQuitKey: .bool("app.warnBeforeQuit"),
        CommandPaletteRenameSelectionSettings.selectAllOnFocusKey: .bool("app.renameSelectsExistingName"),
        CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey: .bool("app.commandPaletteSearchesAllSurfaces"),
        TerminalScrollBarSettings.showScrollBarKey: .bool("terminal.showScrollBar"),
        NotificationBadgeSettings.dockBadgeEnabledKey: .bool("notifications.dockBadge"),
        MenuBarExtraSettings.showInMenuBarKey: .bool("notifications.showInMenuBar"),
        NotificationPaneRingSettings.enabledKey: .bool("notifications.unreadPaneRing"),
        NotificationPaneFlashSettings.enabledKey: .bool("notifications.paneFlash"),
        NotificationSoundSettings.key: .string("notifications.sound"),
        NotificationSoundSettings.customFilePathKey: .string("notifications.customSoundFilePath"),
        NotificationSoundSettings.customCommandKey: .string("notifications.command"),
        SidebarWorkspaceDetailSettings.hideAllDetailsKey: .bool("sidebar.hideAllDetails"),
        SidebarBranchLayoutSettings.key: .bool("sidebar.branchLayout", writeBack: .sidebarBranchLayout),
        SidebarWorkspaceDetailSettings.showNotificationMessageKey: .bool("sidebar.showNotificationMessage"),
        "sidebarShowBranchDirectory": .bool("sidebar.showBranchDirectory"),
        "sidebarShowPullRequest": .bool("sidebar.showPullRequests"),
        SidebarPullRequestClickabilitySettings.key: .bool("sidebar.makePullRequestsClickable"),
        BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey: .bool(
            "sidebar.openPullRequestLinksInCmuxBrowser"
        ),
        BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey: .bool(
            "sidebar.openPortLinksInCmuxBrowser"
        ),
        "sidebarShowSSH": .bool("sidebar.showSSH"),
        "sidebarShowPorts": .bool("sidebar.showPorts"),
        "sidebarShowLog": .bool("sidebar.showLog"),
        "sidebarShowProgress": .bool("sidebar.showProgress"),
        "sidebarShowStatusPills": .bool("sidebar.showCustomMetadata"),
        SidebarActiveTabIndicatorSettings.styleKey: .string("workspaceColors.indicatorStyle"),
        "sidebarSelectionColorHex": .nullableString("workspaceColors.selectionColor"),
        "sidebarNotificationBadgeColorHex": .nullableString("workspaceColors.notificationBadgeColor"),
        WorkspaceTabColorSettings.paletteKey: .stringDictionary("workspaceColors.colors"),
        "sidebarMatchTerminalBackground": .bool("sidebarAppearance.matchTerminalBackground"),
        "sidebarTintHex": .string("sidebarAppearance.tintColor"),
        "sidebarTintHexLight": .nullableString("sidebarAppearance.lightModeTintColor"),
        "sidebarTintHexDark": .nullableString("sidebarAppearance.darkModeTintColor"),
        "sidebarTintOpacity": .double("sidebarAppearance.tintOpacity"),
        SocketControlSettings.appStorageKey: .string("automation.socketControlMode"),
        ClaudeCodeIntegrationSettings.hooksEnabledKey: .bool("automation.claudeCodeIntegration"),
        ClaudeCodeIntegrationSettings.customClaudePathKey: .string("automation.claudeBinaryPath"),
        CursorIntegrationSettings.hooksEnabledKey: .bool("automation.cursorIntegration"),
        GeminiIntegrationSettings.hooksEnabledKey: .bool("automation.geminiIntegration"),
        "cmuxPortBase": .int("automation.portBase"),
        "cmuxPortRange": .int("automation.portRange"),
        BrowserSearchSettings.searchEngineKey: .string("browser.defaultSearchEngine"),
        BrowserSearchSettings.searchSuggestionsEnabledKey: .bool("browser.showSearchSuggestions"),
        BrowserThemeSettings.modeKey: .string("browser.theme"),
        BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey: .bool(
            "browser.openTerminalLinksInCmuxBrowser"
        ),
        BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey: .bool(
            "browser.interceptTerminalOpenCommandInCmuxBrowser"
        ),
        BrowserLinkOpenSettings.browserHostWhitelistKey: .string(
            "browser.hostsToOpenInEmbeddedBrowser",
            writeBack: .newlineSeparatedStringArray
        ),
        BrowserLinkOpenSettings.browserExternalOpenPatternsKey: .string(
            "browser.urlsToAlwaysOpenExternally",
            writeBack: .newlineSeparatedStringArray
        ),
        BrowserInsecureHTTPSettings.allowlistKey: .string(
            "browser.insecureHttpHostsAllowedInEmbeddedBrowser",
            writeBack: .newlineSeparatedStringArray
        ),
        BrowserImportHintSettings.showOnBlankTabsKey: .bool("browser.showImportHintOnBlankTabs"),
        ReactGrabSettings.versionKey: .string("browser.reactGrabVersion"),
        ShortcutHintDebugSettings.showHintsOnCommandHoldKey: .bool("shortcuts.showModifierHoldHints"),
    ]
}
