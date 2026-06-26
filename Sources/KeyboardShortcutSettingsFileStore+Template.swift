import CMUXAgentLaunch
import CmuxBrowser
import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    static func defaultTemplate() -> String {
        var lines: [String] = [
            "{",
            "  \"$schema\": \"\(CmuxSettingsFileSchema.current.schemaURLString)\",",
            "  \"schemaVersion\": \(CmuxSettingsFileSchema.current.version),",
            "",
            "  // This file uses JSON with comments (JSONC).",
            "  // Uncomment and edit any setting to make it file-managed.",
            "  // Remove a setting to fall back to the value saved in Settings.",
            "  // cmux creates this template on launch when ~/.config/cmux/cmux.json is missing.",
            "  // Legacy settings.json files are read only as fallback for keys not present here.",
            "",
        ]

        let sections = defaultTemplateSections()
        for (index, section) in sections.enumerated() {
            lines.append(contentsOf: commentedTemplateLines(for: section))
            if index < sections.count - 1 {
                lines.append("")
            }
        }

        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func commentedTemplateLines(for section: [String: Any]) -> [String] {
        let json = prettyJSONString(section)
        let sectionLines = json
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard sectionLines.count >= 2 else { return [] }

        return sectionLines
            .dropFirst()
            .dropLast()
            .enumerated()
            .map { index, line in
                if index == sectionLines.count - 3 {
                    return "  // \(line),"
                }
                return "  // \(line)"
            }
    }

    private static func defaultTemplateSections() -> [[String: Any]] {
        let shortcutsBindings = Dictionary(
            uniqueKeysWithValues: KeyboardShortcutSettings.publicShortcutActions.map { action in
                (action.rawValue, shortcutTemplateValue(action.defaultShortcut, usesNumberedDigits: action.usesNumberedDigitMatching))
            }
        )

        return [
            [
                "app": [
                    "language": AppCatalogSection().language.defaultValue.rawValue,
                    "appearance": AppearanceSettings.defaultMode.rawValue,
                    "appIcon": AppCatalogSection().appIcon.defaultValue.rawValue,
                    "windowTitleTemplate": WindowTitleTemplate.defaultRawValue,
                    "menuBarOnly": MenuBarOnlySettings.defaultMenuBarOnly,
                    "newWorkspacePlacement": SettingCatalog().app.newWorkspacePlacement.defaultValue.rawValue,
                    "forkConversationDefaultDestination": AgentConversationForkDestination.defaultDestination.rawValue,
                    "workspaceInheritWorkingDirectory": SettingCatalog().app.workspaceInheritWorkingDirectory.defaultValue,
                    "minimalMode": false,
                    "keepWorkspaceOpenWhenClosingLastSurface": !SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface.defaultValue,
                    "focusPaneOnFirstClick": PaneFirstClickFocusSettings.defaultEnabled,
                    "preferredEditor": "",
                    "openSupportedFilesInCmux": AppCatalogSection().openSupportedFilesInCmux.defaultValue,
                    "openMarkdownInCmuxViewer": AppCatalogSection().openMarkdownInCmuxViewer.defaultValue,
                    "reorderOnNotification": SettingCatalog().app.reorderOnNotification.defaultValue,
                    "iMessageMode": IMessageModeSettings.defaultValue,
                    "sendAnonymousTelemetry": AppCatalogSection().sendAnonymousTelemetry.defaultValue,
                    "confirmQuit": AppCatalogSection().confirmQuitMode.defaultValue.rawValue,
                    "warnBeforeClosingTab": AppCatalogSection().warnBeforeClosingTab.defaultValue,
                    "warnBeforeClosingTabXButton": AppCatalogSection().warnBeforeClosingTabXButton.defaultValue,
                    "hideTabCloseButton": AppCatalogSection().hideTabCloseButton.defaultValue,
                    "renameSelectsExistingName": AppCatalogSection().renameSelectsExistingName.defaultValue,
                    "commandPaletteSearchesAllSurfaces": AppCatalogSection().commandPaletteSearchesAllSurfaces.defaultValue,
                ],
            ],
            [
                "workspaceGroups": [
                    "newWorkspacePlacement": SettingCatalog().workspaceGroups.newWorkspacePlacement.defaultValue.rawValue,
                ],
            ],
            [
                "terminal": [
                    "showScrollBar": TerminalScrollBarSettings.defaultShowScrollBar,
                    "copyOnSelect": TerminalCopyOnSelectSettings.defaultCopyOnSelect,
                    "autoResumeAgentSessions": AgentSessionAutoResumeSettings.defaultAutoResumeAgentSessions,
                    "showTextBoxOnNewTerminals": TerminalTextBoxInputSettings.defaultShowOnNewTerminals,
                    "focusTextBoxOnNewTerminals": TerminalTextBoxInputSettings.defaultFocusOnNewTerminals,
                    "agentHibernation": [
                        "enabled": AgentHibernationSettings.defaultEnabled,
                        "idleSeconds": Int(AgentHibernationSettings.defaultIdleSeconds),
                        "maxLiveTerminals": AgentHibernationSettings.defaultMaxLiveTerminals,
                    ],
                    "rendererRealization": [
                        "enabled": RendererRealizationSettings.defaultEnabled,
                        "idleSeconds": Int(RendererRealizationSettings.defaultIdleSeconds),
                        "maxWarmRenderers": RendererRealizationSettings.defaultMaxWarmRenderers,
                    ],
                    "textBoxMaxLines": TerminalTextBoxInputSettings.defaultMaxLines,
                    "resumeCommands": [],
                ],
            ],
            [
                "notifications": [
                    "dockBadge": NotificationBadgeSettings.defaultDockBadgeEnabled,
                    "showInMenuBar": MenuBarExtraSettings.defaultShowInMenuBar,
                    "unreadPaneRing": NotificationPaneRingSettings.defaultEnabled,
                    "paneFlash": NotificationPaneFlashSettings.defaultEnabled,
                    "sound": NotificationSoundSettings.defaultValue,
                    "customSoundFilePath": NotificationSoundSettings.defaultCustomFilePath,
                    "command": NotificationSoundSettings.defaultCustomCommand,
                    "hooksMode": "append",
                    "hooks": [],
                ],
            ],
            [
                "sidebar": [
                    "hideAllDetails": SettingCatalog().sidebar.hideAllDetails.defaultValue,
                    "wrapWorkspaceTitles": SidebarWorkspaceTitleWrapSettings.defaultWrap,
                    "showWorkspaceDescription": SettingCatalog().sidebar.showWorkspaceDescription.defaultValue,
                    "branchLayout": SettingCatalog().sidebar.branchVerticalLayout.defaultValue ? "vertical" : "inline",
                    "stackBranchDirectory": SettingCatalog().sidebar.stackBranchDirectory.defaultValue,
                    "pathLastSegmentOnly": SettingCatalog().sidebar.pathLastSegmentOnly.defaultValue,
                    "showNotificationMessage": SettingCatalog().sidebar.showNotificationMessage.defaultValue,
                    "showBranchDirectory": SidebarWorkspaceDetailDefaults.showBranchDirectory,
                    "showPullRequests": SidebarWorkspaceDetailDefaults.showPullRequests,
                    "watchGitStatus": SidebarWorkspaceDetailDefaults.watchGitStatus,
                    "makePullRequestsClickable": SettingCatalog().sidebar.makePullRequestsClickable.defaultValue,
                    "openPullRequestLinksInCmuxBrowser": BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser,
                    "openPortLinksInCmuxBrowser": BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser,
                    "showSSH": SidebarWorkspaceDetailDefaults.showSSH,
                    "showPorts": SidebarWorkspaceDetailDefaults.showPorts,
                    "showLog": SidebarWorkspaceDetailDefaults.showLog,
                    "showProgress": SidebarWorkspaceDetailDefaults.showProgress,
                    "showCustomMetadata": SidebarWorkspaceDetailDefaults.showCustomMetadata,
                ],
            ],
            [
                "workspaceColors": [
                    "indicatorStyle": SettingCatalog().workspaceColors.indicatorStyle.defaultValue.rawValue,
                    "selectionColor": NSNull(),
                    "notificationBadgeColor": NSNull(),
                    "colors": Dictionary(
                        uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) }
                    ),
                ],
            ],
            [
                "sidebarAppearance": [
                    "matchTerminalBackground": false,
                    "tintColor": SidebarTintDefaults().hex,
                    "lightModeTintColor": NSNull(),
                    "darkModeTintColor": NSNull(),
                    "tintOpacity": SidebarTintDefaults().opacity,
                ],
            ],
            [
                "automation": [
                    "socketControlMode": SocketControlSettings.defaultMode.rawValue,
                    "socketPassword": "",
                    "claudeCodeIntegration": IntegrationsCatalogSection().claudeCodeHooksEnabled.defaultValue,
                    "claudeBinaryPath": "",
                    "ripgrepBinaryPath": "",
                    "suppressSubagentNotifications": IntegrationsCatalogSection().suppressSubagentNotifications.defaultValue,
                    "ampIntegration": IntegrationsCatalogSection().ampHooksEnabled.defaultValue,
                    "cursorIntegration": IntegrationsCatalogSection().cursorHooksEnabled.defaultValue,
                    "geminiIntegration": IntegrationsCatalogSection().geminiHooksEnabled.defaultValue,
                    "kiroIntegration": IntegrationsCatalogSection().kiroHooksEnabled.defaultValue,
                    "kiroNotificationLevel": IntegrationsCatalogSection().kiroNotificationLevel.defaultValue,
                    "portBase": AutomationSettings.defaultPortBase,
                    "portRange": AutomationSettings.defaultPortRange,
                ],
            ],
            [
                "browser": [
                    "defaultSearchEngine": BrowserSearchSettingsStore.defaultSearchEngine.rawValue,
                    "customSearchEngineName": BrowserSearchSettingsStore.defaultCustomSearchEngineName,
                    "customSearchEngineURLTemplate": BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate,
                    "showSearchSuggestions": BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
                    "theme": BrowserThemeSettings.defaultMode.rawValue,
                    "discardHiddenWebViews": BrowserHiddenWebViewDiscardPolicy.defaultEnabled,
                    "hiddenWebViewDiscardDelaySeconds": BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
                    "openTerminalLinksInCmuxBrowser": BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser,
                    "interceptTerminalOpenCommandInCmuxBrowser": BrowserLinkOpenSettings.defaultInterceptTerminalOpenCommandInCmuxBrowser,
                    "hostsToOpenInEmbeddedBrowser": [String](),
                    "urlsToAlwaysOpenExternally": [String](),
                    "insecureHttpHostsAllowedInEmbeddedBrowser": BrowserInsecureHTTPSettings.defaultAllowlistPatterns,
                    "showImportHintOnBlankTabs": BrowserImportHintSettings.defaultShowOnBlankTabs,
                    "reactGrabVersion": ReactGrabSettings.defaultVersion,
                ],
            ],
            [
                "markdown": [
                    "fontSize": Int(MarkdownFontSizeSettings.defaultPointSize),
                    "fontFamily": "",
                    "maxWidth": Int(MarkdownMaxWidthSettings.defaultCSSPixels),
                ],
            ],
            [
                "fileEditor": [
                    "wordWrap": FilePreviewWordWrapSettings.defaultEnabled,
                ],
            ],
            [
                "fileExplorer": [
                    "doubleClickAction": FileExplorerDoubleClickActionSettings.defaultValue.rawValue,
                ],
            ],
            [
                "diffViewer": [
                    "defaultLayout": "unified",
                ],
            ],
            [
                "shortcuts": [
                    "bindings": shortcutsBindings,
                ],
            ],
        ]
    }

    private static func shortcutTemplateValue(
        _ shortcut: StoredShortcut,
        usesNumberedDigits: Bool
    ) -> Any {
        if let secondStroke = shortcut.secondStroke {
            return [
                shortcut.firstStroke.configString(preserveDigit: !usesNumberedDigits),
                secondStroke.configString(preserveDigit: true),
            ]
        }
        return shortcut.firstStroke.configString(preserveDigit: true)
    }

    private static func prettyJSONString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
