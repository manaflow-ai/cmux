import Foundation

extension CmuxSettingsFileStore {
    static func defaultTemplate() -> String {
        var lines: [String] = [
            "{",
            "  \"$schema\": \"\(schemaURLString)\",",
            "  \"schemaVersion\": \(currentSchemaVersion),",
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
        let json: String
        do {
            json = try prettyJSONString(section)
        } catch {
            preconditionFailure("Failed to render default cmux.json template section: \(error)")
        }

        let sectionLines = json
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard sectionLines.count >= 2 else {
            preconditionFailure("Rendered default cmux.json template section is not an object")
        }

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
                    "language": LanguageSettings.defaultLanguage.rawValue,
                    "appearance": AppearanceSettings.defaultMode.rawValue,
                    "appIcon": AppIconSettings.defaultMode.rawValue,
                    "menuBarOnly": MenuBarOnlySettings.defaultMenuBarOnly,
                    "newWorkspacePlacement": WorkspacePlacementSettings.defaultPlacement.rawValue,
                    "minimalMode": false,
                    "keepWorkspaceOpenWhenClosingLastSurface": !LastSurfaceCloseShortcutSettings.defaultValue,
                    "focusPaneOnFirstClick": PaneFirstClickFocusSettings.defaultEnabled,
                    "preferredEditor": "",
                    "openMarkdownInCmuxViewer": CmdClickMarkdownRouteSettings.defaultValue,
                    "reorderOnNotification": WorkspaceAutoReorderSettings.defaultValue,
                    "iMessageMode": IMessageModeSettings.defaultValue,
                    "sendAnonymousTelemetry": TelemetrySettings.defaultSendAnonymousTelemetry,
                    "warnBeforeQuit": QuitWarningSettings.defaultWarnBeforeQuit,
                    "renameSelectsExistingName": CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus,
                    "commandPaletteSearchesAllSurfaces": CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces,
                ],
            ],
            [
                "terminal": [
                    "showScrollBar": TerminalScrollBarSettings.defaultShowScrollBar,
                    "autoResumeAgentSessions": AgentSessionAutoResumeSettings.defaultAutoResumeAgentSessions,
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
                ],
            ],
            [
                "sidebar": [
                    "hideAllDetails": SidebarWorkspaceDetailSettings.defaultHideAllDetails,
                    "branchLayout": SidebarBranchLayoutSettings.defaultVerticalLayout ? "vertical" : "inline",
                    "showNotificationMessage": SidebarWorkspaceDetailSettings.defaultShowNotificationMessage,
                    "showBranchDirectory": true,
                    "showPullRequests": true,
                    "makePullRequestsClickable": SidebarPullRequestClickabilitySettings.defaultClickable,
                    "openPullRequestLinksInCmuxBrowser": BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser,
                    "openPortLinksInCmuxBrowser": BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser,
                    "showSSH": true,
                    "showPorts": true,
                    "showLog": true,
                    "showProgress": true,
                    "showCustomMetadata": true,
                ],
            ],
            [
                "workspaceColors": [
                    "indicatorStyle": SidebarActiveTabIndicatorSettings.defaultStyle.rawValue,
                    "selectionColor": NSNull(),
                    "notificationBadgeColor": NSNull(),
                    "colors": Dictionary(
                        uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) }
                    )
                ],
            ],
            [
                "sidebarAppearance": [
                    "matchTerminalBackground": false,
                    "tintColor": SidebarTintDefaults.hex,
                    "lightModeTintColor": NSNull(),
                    "darkModeTintColor": NSNull(),
                    "tintOpacity": SidebarTintDefaults.opacity,
                ],
            ],
            [
                "automation": [
                    "socketControlMode": SocketControlSettings.defaultMode.rawValue,
                    "socketPassword": "",
                    "claudeCodeIntegration": ClaudeCodeIntegrationSettings.defaultHooksEnabled,
                    "claudeBinaryPath": "",
                    "cursorIntegration": CursorIntegrationSettings.defaultHooksEnabled,
                    "geminiIntegration": GeminiIntegrationSettings.defaultHooksEnabled,
                    "portBase": 9100,
                    "portRange": 10,
                ],
            ],
            [
                "browser": [
                    "defaultSearchEngine": BrowserSearchSettings.defaultSearchEngine.rawValue,
                    "showSearchSuggestions": BrowserSearchSettings.defaultSearchSuggestionsEnabled,
                    "theme": BrowserThemeSettings.defaultMode.rawValue,
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
        let defaultShortcut = usesNumberedDigits ? (shortcut.secondStroke ?? shortcut.firstStroke) : nil
        let rendered = shortcut.firstStroke.configString(preserveDigit: !usesNumberedDigits)
        if let secondStroke = shortcut.secondStroke {
            return [rendered, secondStroke.configString(preserveDigit: true)]
        }
        if let defaultShortcut {
            return defaultShortcut.configString(preserveDigit: true)
        }
        return rendered
    }

    private static func prettyJSONString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return string
    }
}
