import Combine
import CmuxFileWatch
import CmuxSocketControl
import Foundation
import os


// MARK: - Settings File Parsing
extension CmuxSettingsFileStore {
    func parseSettingsFile(root: [String: Any], sourcePath: String) -> ResolvedSettingsSnapshot {
        let schemaVersion = jsonInt(root["schemaVersion"]) ?? 1
        if schemaVersion > Self.currentSchemaVersion {
            cmuxSettingsFileStoreLogger.warning("\(sourcePath, privacy: .private(mask: .hash)) uses future schemaVersion \(schemaVersion, privacy: .private(mask: .hash)); parsing known fields only")
        }

        var snapshot = ResolvedSettingsSnapshot(path: sourcePath)

        if let appSection = root["app"] as? [String: Any] {
            parseAppSection(appSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let terminalSection = root["terminal"] as? [String: Any] {
            parseTerminalSection(terminalSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let notificationsSection = root["notifications"] as? [String: Any] {
            parseNotificationsSection(notificationsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let sidebarSection = root["sidebar"] as? [String: Any] {
            parseSidebarSection(sidebarSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let workspaceColorsSection = root["workspaceColors"] as? [String: Any] {
            parseWorkspaceColorsSection(workspaceColorsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let sidebarAppearanceSection = root["sidebarAppearance"] as? [String: Any] {
            parseSidebarAppearanceSection(sidebarAppearanceSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let automationSection = root["automation"] as? [String: Any] {
            parseAutomationSection(automationSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let browserSection = root["browser"] as? [String: Any] {
            parseBrowserSection(browserSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let markdownSection = root["markdown"] as? [String: Any] {
            parseMarkdownSection(markdownSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let fileEditorSection = root["fileEditor"] as? [String: Any] {
            parseFileEditorSection(fileEditorSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let workspaceGroupsSection = root["workspaceGroups"] as? [String: Any] {
            parseWorkspaceGroupsSection(workspaceGroupsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }
        if let shortcutsSection = root["shortcuts"] {
            parseShortcutsSection(shortcutsSection, sourcePath: sourcePath, snapshot: &snapshot)
        }

        return snapshot
    }

    private func parseAppSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["language"]) {
            guard let language = AppLanguage(rawValue: raw) else {
                logInvalid("app.language", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[LanguageSettings.languageKey] = .string(language.rawValue)
        }
        if let raw = jsonString(section["appearance"]) {
            let normalized = AppearanceSettings.mode(for: raw).rawValue
            let accepted = Set(AppearanceMode.allCases.map(\.rawValue))
            guard accepted.contains(raw) else {
                logInvalid("app.appearance", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AppearanceSettings.appearanceModeKey] = .string(normalized)
        }
        if let raw = jsonString(section["appIcon"]) {
            guard let mode = AppIconMode(rawValue: raw) else {
                logInvalid("app.appIcon", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AppIconSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["menuBarOnly"]) {
            snapshot.managedUserDefaults[MenuBarOnlySettings.menuBarOnlyKey] = .bool(value)
        }
        if let raw = jsonString(section["newWorkspacePlacement"]) {
            guard let placement = NewWorkspacePlacement(rawValue: raw) else {
                logInvalid("app.newWorkspacePlacement", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[WorkspacePlacementSettings.placementKey] = .string(placement.rawValue)
        }
        if let raw = jsonString(section["forkConversationDefaultDestination"]) {
            if let destination = AgentConversationForkDestination(rawValue: raw) {
                snapshot.managedUserDefaults[AgentConversationForkDefaultSettings.key] = .string(destination.rawValue)
            } else {
                logInvalid("app.forkConversationDefaultDestination", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["workspaceInheritWorkingDirectory"]) {
            snapshot.managedUserDefaults[WorkspaceWorkingDirectoryInheritanceSettings.key] = .bool(value)
        } else if section.keys.contains("workspaceInheritWorkingDirectory") {
            logInvalid("app.workspaceInheritWorkingDirectory", sourcePath: sourcePath)
        }
        if let value = jsonBool(section["minimalMode"]) {
            let mode = value ? WorkspacePresentationModeSettings.Mode.minimal : .standard
            snapshot.managedUserDefaults[WorkspacePresentationModeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["keepWorkspaceOpenWhenClosingLastSurface"]) {
            snapshot.managedUserDefaults[LastSurfaceCloseShortcutSettings.key] = .bool(!value)
        }
        if let value = jsonBool(section["focusPaneOnFirstClick"]) {
            snapshot.managedUserDefaults[PaneFirstClickFocusSettings.enabledKey] = .bool(value)
        }
        if let value = jsonString(section["preferredEditor"]) {
            snapshot.managedUserDefaults[PreferredEditorSettings.key] = .string(value)
        }
        if let value = jsonBool(section["openSupportedFilesInCmux"]) {
            snapshot.managedUserDefaults[CmdClickSupportedFileRouteSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["openMarkdownInCmuxViewer"]) {
            snapshot.managedUserDefaults[CmdClickMarkdownRouteSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["reorderOnNotification"]) {
            snapshot.managedUserDefaults[WorkspaceAutoReorderSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["iMessageMode"]) {
            snapshot.managedUserDefaults[IMessageModeSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["sendAnonymousTelemetry"]) {
            snapshot.managedUserDefaults[TelemetrySettings.sendAnonymousTelemetryKey] = .bool(value)
        }
        var parsedConfirmQuitMode: QuitConfirmationMode?
        if let raw = jsonString(section["confirmQuit"]) {
            if let mode = QuitConfirmationMode(rawValue: raw) {
                parsedConfirmQuitMode = mode
                snapshot.managedUserDefaults[QuitWarningSettings.confirmQuitKey] = .string(mode.rawValue)
            } else {
                logInvalid("app.confirmQuit", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["warnBeforeQuit"]) {
            snapshot.managedUserDefaults[QuitWarningSettings.warnBeforeQuitKey] = .bool(value)
            if parsedConfirmQuitMode == nil {
                let mode: QuitConfirmationMode = value ? .always : .never
                snapshot.managedUserDefaults[QuitWarningSettings.confirmQuitKey] = .string(mode.rawValue)
                snapshot.legacyDerivedManagedUserDefaultKeys.insert(QuitWarningSettings.confirmQuitKey)
            }
        }
        if let value = jsonBool(section["warnBeforeClosingTab"]) {
            snapshot.managedUserDefaults[CloseTabWarningSettings.warnBeforeClosingTabKey] = .bool(value)
        }
        if let value = jsonBool(section["warnBeforeClosingTabXButton"]) {
            snapshot.managedUserDefaults[CloseTabWarningSettings.warnBeforeClosingTabXButtonKey] = .bool(value)
        }
        if let value = jsonBool(section["hideTabCloseButton"]) {
            snapshot.managedUserDefaults[CloseTabWarningSettings.hideTabCloseButtonKey] = .bool(value)
        }
        if let value = jsonBool(section["renameSelectsExistingName"]) {
            snapshot.managedUserDefaults[CommandPaletteRenameSelectionSettings.selectAllOnFocusKey] = .bool(value)
        }
        if let value = jsonBool(section["commandPaletteSearchesAllSurfaces"]) {
            snapshot.managedUserDefaults[CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey] = .bool(value)
        }
    }

    private func parseNotificationsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["dockBadge"]) {
            snapshot.managedUserDefaults[NotificationBadgeSettings.dockBadgeEnabledKey] = .bool(value)
        }
        if let value = jsonBool(section["showInMenuBar"]) {
            snapshot.managedUserDefaults[MenuBarExtraSettings.showInMenuBarKey] = .bool(value)
        }
        if let value = jsonBool(section["unreadPaneRing"]) {
            snapshot.managedUserDefaults[NotificationPaneRingSettings.enabledKey] = .bool(value)
        }
        if let value = jsonBool(section["paneFlash"]) {
            snapshot.managedUserDefaults[NotificationPaneFlashSettings.enabledKey] = .bool(value)
        }
        if let raw = jsonString(section["sound"]) {
            let allowed = Set(NotificationSoundSettings.systemSounds.map(\.value))
            guard allowed.contains(raw) else {
                logInvalid("notifications.sound", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[NotificationSoundSettings.key] = .string(raw)
        }
        if let raw = jsonString(section["customSoundFilePath"]) {
            snapshot.managedUserDefaults[NotificationSoundSettings.customFilePathKey] = .string(raw)
        }
        if let raw = jsonString(section["command"]) {
            snapshot.managedUserDefaults[NotificationSoundSettings.customCommandKey] = .string(raw)
        }
    }

    private func parseTerminalSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["showScrollBar"]) {
            snapshot.managedUserDefaults[TerminalScrollBarSettings.showScrollBarKey] = .bool(value)
        } else if section.keys.contains("showScrollBar") {
            logInvalid("terminal.showScrollBar", sourcePath: sourcePath)
        }

        if let value = jsonBool(section["copyOnSelect"]) {
            snapshot.managedUserDefaults[TerminalCopyOnSelectSettings.copyOnSelectKey] = .bool(value)
        } else if section.keys.contains("copyOnSelect") {
            logInvalid("terminal.copyOnSelect", sourcePath: sourcePath)
        }

        if let value = jsonBool(section["autoResumeAgentSessions"]) {
            snapshot.managedUserDefaults[AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey] = .bool(value)
        } else if section.keys.contains("autoResumeAgentSessions") {
            logInvalid("terminal.autoResumeAgentSessions", sourcePath: sourcePath)
        }

        if let value = jsonBool(section["showTextBoxOnNewTerminals"]) {
            snapshot.managedUserDefaults[TerminalTextBoxInputSettings.showOnNewTerminalsKey] = .bool(value)
        } else if section.keys.contains("showTextBoxOnNewTerminals") {
            logInvalid("terminal.showTextBoxOnNewTerminals", sourcePath: sourcePath)
        }

        if let value = jsonBool(section["focusTextBoxOnNewTerminals"]) {
            snapshot.managedUserDefaults[TerminalTextBoxInputSettings.focusOnNewTerminalsKey] = .bool(value)
        } else if section.keys.contains("focusTextBoxOnNewTerminals") {
            logInvalid("terminal.focusTextBoxOnNewTerminals", sourcePath: sourcePath)
        }

        if let rawHibernation = section["agentHibernation"],
           let hibernation = rawHibernation as? [String: Any] {
            if let value = jsonBool(hibernation["enabled"]) {
                snapshot.managedUserDefaults[AgentHibernationSettings.enabledKey] = .bool(value)
            } else if hibernation.keys.contains("enabled") {
                logInvalid("terminal.agentHibernation.enabled", sourcePath: sourcePath)
            }
            if let value = jsonInt(hibernation["idleSeconds"]) {
                snapshot.managedUserDefaults[AgentHibernationSettings.idleSecondsKey] = .double(
                    AgentHibernationSettings.sanitizedIdleSeconds(TimeInterval(value))
                )
            } else if hibernation.keys.contains("idleSeconds") {
                logInvalid("terminal.agentHibernation.idleSeconds", sourcePath: sourcePath)
            }
            if let value = jsonInt(hibernation["maxLiveTerminals"]) {
                snapshot.managedUserDefaults[AgentHibernationSettings.maxLiveTerminalsKey] = .int(
                    AgentHibernationSettings.sanitizedMaxLiveTerminals(value)
                )
            } else if hibernation.keys.contains("maxLiveTerminals") {
                logInvalid("terminal.agentHibernation.maxLiveTerminals", sourcePath: sourcePath)
            }
        } else if section.keys.contains("agentHibernation") {
            logInvalid("terminal.agentHibernation", sourcePath: sourcePath)
        }

        if let value = jsonInt(section["textBoxMaxLines"]) {
            if value >= TerminalTextBoxInputSettings.minimumMaxLines,
               value <= TerminalTextBoxInputSettings.maximumMaxLines {
                snapshot.managedUserDefaults[TerminalTextBoxInputSettings.maxLinesKey] = .int(value)
            } else {
                logInvalid("terminal.textBoxMaxLines", sourcePath: sourcePath)
            }
        } else if section.keys.contains("textBoxMaxLines") {
            logInvalid("terminal.textBoxMaxLines", sourcePath: sourcePath)
        }
    }

    private func parseMarkdownSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        // Accept numeric doubles (e.g. 15 or 15.0) and round to integer points,
        // matching the integer `markdown.fontSize` catalog/UI representation.
        if let value = jsonDouble(section["fontSize"]) {
            if value >= MarkdownFontSizeSettings.minimumPointSize,
               value <= MarkdownFontSizeSettings.maximumPointSize {
                snapshot.managedUserDefaults[MarkdownFontSizeSettings.key] = .int(Int(value.rounded()))
            } else {
                logInvalid("markdown.fontSize", sourcePath: sourcePath)
            }
        } else if section.keys.contains("fontSize") {
            logInvalid("markdown.fontSize", sourcePath: sourcePath)
        }

        if let value = jsonString(section["fontFamily"]) {
            snapshot.managedUserDefaults[MarkdownFontFamily.key] = .string(MarkdownFontFamily.normalized(value))
        } else if section.keys.contains("fontFamily") {
            logInvalid("markdown.fontFamily", sourcePath: sourcePath)
        }

        if let value = jsonDouble(section["maxWidth"]) {
            if value >= MarkdownMaxWidthSettings.minimumCSSPixels,
               value <= MarkdownMaxWidthSettings.maximumCSSPixels {
                snapshot.managedUserDefaults[MarkdownMaxWidthSettings.key] = .int(Int(value.rounded()))
            } else {
                logInvalid("markdown.maxWidth", sourcePath: sourcePath)
            }
        } else if section.keys.contains("maxWidth") {
            logInvalid("markdown.maxWidth", sourcePath: sourcePath)
        }
    }

    private func parseFileEditorSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["wordWrap"]) {
            snapshot.managedUserDefaults[FilePreviewWordWrapSettings.key] = .bool(value)
        } else if section.keys.contains("wordWrap") {
            logInvalid("fileEditor.wordWrap", sourcePath: sourcePath)
        }
    }

    private func parseSidebarSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["hideAllDetails"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceDetailSettings.hideAllDetailsKey] = .bool(value)
        }
        if let value = jsonBool(section["wrapWorkspaceTitles"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceTitleWrapSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["showWorkspaceDescription"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceDetailSettings.showWorkspaceDescriptionKey] = .bool(value)
        }
        if let raw = jsonString(section["branchLayout"]) {
            switch raw {
            case "vertical":
                snapshot.managedUserDefaults[SidebarBranchLayoutSettings.key] = .bool(true)
            case "inline":
                snapshot.managedUserDefaults[SidebarBranchLayoutSettings.key] = .bool(false)
            default:
                logInvalid("sidebar.branchLayout", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["stackBranchDirectory"]) {
            snapshot.managedUserDefaults[SidebarBranchDirectoryStackedSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["pathLastSegmentOnly"]) {
            snapshot.managedUserDefaults[SidebarPathLastSegmentSettings.key] = .bool(value)
        }
        if let value = jsonBool(section["showNotificationMessage"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceDetailSettings.showNotificationMessageKey] = .bool(value)
        }
        if let value = jsonBool(section["showBranchDirectory"]) { snapshot.managedUserDefaults["sidebarShowBranchDirectory"] = .bool(value) }
        if let value = jsonBool(section["showPullRequests"]) { snapshot.managedUserDefaults["sidebarShowPullRequest"] = .bool(value) }
        if let value = jsonBool(section["watchGitStatus"]) { snapshot.managedUserDefaults[SidebarWorkspaceDetailDefaults.watchGitStatusKey] = .bool(value) }
        if let value = jsonBool(section["makePullRequestsClickable"]) { snapshot.managedUserDefaults[SidebarPullRequestClickabilitySettings.key] = .bool(value) }
        if let value = jsonBool(section["openPullRequestLinksInCmuxBrowser"]) {
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey] = .bool(value)
        }
        if let value = jsonBool(section["openPortLinksInCmuxBrowser"]) {
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey] = .bool(value)
        }
        if let value = jsonBool(section["showSSH"]) {
            snapshot.managedUserDefaults["sidebarShowSSH"] = .bool(value)
        }
        if let value = jsonBool(section["showPorts"]) {
            snapshot.managedUserDefaults["sidebarShowPorts"] = .bool(value)
        }
        if let value = jsonBool(section["showLog"]) {
            snapshot.managedUserDefaults["sidebarShowLog"] = .bool(value)
        }
        if let value = jsonBool(section["showProgress"]) {
            snapshot.managedUserDefaults["sidebarShowProgress"] = .bool(value)
        }
        if let value = jsonBool(section["showCustomMetadata"]) {
            snapshot.managedUserDefaults["sidebarShowStatusPills"] = .bool(value)
        }
    }

    private func parseWorkspaceColorsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["indicatorStyle"]) {
            let normalized = SidebarActiveTabIndicatorSettings.resolvedStyle(rawValue: raw).rawValue
            let accepted = Set(SidebarActiveTabIndicatorStyle.allCases.map(\.rawValue)).union([
                "rail", "border", "wash", "lift", "typography", "washRail", "blueWashColorRail",
            ])
            guard accepted.contains(raw) else {
                logInvalid("workspaceColors.indicatorStyle", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[SidebarActiveTabIndicatorSettings.styleKey] = .string(normalized)
        }
        if section.keys.contains("selectionColor") {
            guard let value = parseNullableHex(
                section["selectionColor"],
                path: "workspaceColors.selectionColor",
                sourcePath: sourcePath
            ) else { return }
            snapshot.managedUserDefaults["sidebarSelectionColorHex"] = .nullableString(value)
        }
        if section.keys.contains("notificationBadgeColor") {
            guard let value = parseNullableHex(
                section["notificationBadgeColor"],
                path: "workspaceColors.notificationBadgeColor",
                sourcePath: sourcePath
            ) else { return }
            snapshot.managedUserDefaults["sidebarNotificationBadgeColorHex"] = .nullableString(value)
        }
        if section.keys.contains("colors") {
            guard let rawColors = section["colors"] as? [String: Any] else {
                logInvalid("workspaceColors.colors", sourcePath: sourcePath)
                return
            }

            var normalizedPalette: [String: String] = [:]
            for (rawName, rawValue) in rawColors {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else {
                    cmuxSettingsFileStoreLogger.warning("ignoring empty workspace color name in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    cmuxSettingsFileStoreLogger.warning("ignoring invalid workspace color '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                normalizedPalette[name] = normalizedHex
            }
            snapshot.managedUserDefaults[WorkspaceTabColorSettings.paletteKey] = .stringDictionary(normalizedPalette)
            return
        }

        let validNames = Set(WorkspaceTabColorSettings.defaultPalette.map(\.name))
        var normalizedLegacyPalette: [String: String]? = nil
        if let rawOverrides = section["paletteOverrides"] as? [String: Any] {
            var palette = Dictionary(
                uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) }
            )
            for (name, rawValue) in rawOverrides {
                guard validNames.contains(name) else {
                    cmuxSettingsFileStoreLogger.warning("ignoring unknown workspace color '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    cmuxSettingsFileStoreLogger.warning("ignoring invalid workspace color override '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                palette[name] = normalizedHex
            }
            normalizedLegacyPalette = palette
        }
        if let rawCustomColors = jsonStringArray(section["customColors"]) {
            var palette = normalizedLegacyPalette ?? Dictionary(
                uniqueKeysWithValues: WorkspaceTabColorSettings.defaultPalette.map { ($0.name, $0.hex) }
            )
            var existingNames = Set(palette.keys)
            var seenCustomHexes: Set<String> = []
            for rawHex in rawCustomColors {
                guard let normalizedHex = WorkspaceTabColorSettings.normalizedHex(rawHex),
                      seenCustomHexes.insert(normalizedHex).inserted else { continue }
                var index = 1
                while existingNames.contains("Custom \(index)") {
                    index += 1
                }
                let name = "Custom \(index)"
                palette[name] = normalizedHex
                existingNames.insert(name)
            }
            normalizedLegacyPalette = palette
        }
        if let normalizedLegacyPalette {
            snapshot.managedUserDefaults[WorkspaceTabColorSettings.paletteKey] = .stringDictionary(normalizedLegacyPalette)
        }
    }

    private func parseSidebarAppearanceSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["matchTerminalBackground"]) {
            snapshot.managedUserDefaults[SidebarMatchTerminalBackgroundSettings.userDefaultsKey] = .bool(value)
        }
        if let raw = jsonString(section["tintColor"]) {
            guard let normalized = WorkspaceTabColorSettings.normalizedHex(raw) else {
                logInvalid("sidebarAppearance.tintColor", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults["sidebarTintHex"] = .string(normalized)
        }
        if section.keys.contains("lightModeTintColor") {
            guard let value = parseNullableHex(
                section["lightModeTintColor"],
                path: "sidebarAppearance.lightModeTintColor",
                sourcePath: sourcePath
            ) else { return }
            snapshot.managedUserDefaults["sidebarTintHexLight"] = .nullableString(value)
        }
        if section.keys.contains("darkModeTintColor") {
            guard let value = parseNullableHex(
                section["darkModeTintColor"],
                path: "sidebarAppearance.darkModeTintColor",
                sourcePath: sourcePath
            ) else { return }
            snapshot.managedUserDefaults["sidebarTintHexDark"] = .nullableString(value)
        }
        if let value = jsonDouble(section["tintOpacity"]) {
            let clamped = min(max(value, 0), 1)
            snapshot.managedUserDefaults["sidebarTintOpacity"] = .double(clamped)
        }
    }

    private func parseAutomationSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["socketControlMode"]) {
            let knownModes = Set([
                "off", "cmuxonly", "automation", "password", "allowall", "openaccess", "fullopenaccess",
                "notifications", "full",
            ])
            let normalizedRaw = raw.replacingOccurrences(of: "-", with: "").lowercased()
            guard knownModes.contains(normalizedRaw) else {
                logInvalid("automation.socketControlMode", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[SocketControlSettings.appStorageKey] = .string(
                SocketControlSettings.migrateMode(raw).rawValue
            )
        }
        if section.keys.contains("socketPassword") {
            if section["socketPassword"] is NSNull {
                snapshot.managedCustomSettings.socketPassword = .clear
            } else if let raw = jsonString(section["socketPassword"]) {
                snapshot.managedCustomSettings.socketPassword = raw.isEmpty ? .clear : .set(raw)
            } else {
                logInvalid("automation.socketPassword", sourcePath: sourcePath)
                return
            }
        }
        if let value = jsonBool(section["claudeCodeIntegration"]) {
            snapshot.managedUserDefaults[ClaudeCodeIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let raw = jsonString(section["claudeBinaryPath"]) {
            snapshot.managedUserDefaults[ClaudeCodeIntegrationSettings.customClaudePathKey] = .string(raw)
        }
        if let raw = jsonString(section["ripgrepBinaryPath"]) {
            snapshot.managedUserDefaults[RipgrepIntegrationSettings.customRipgrepPathKey] = .string(raw)
        }
        if let value = jsonBool(section["suppressSubagentNotifications"]) {
            snapshot.managedUserDefaults[AgentSubagentNotificationSettings.suppressNotificationsKey] = .bool(value)
        }
        if let value = jsonBool(section["ampIntegration"]) {
            snapshot.managedUserDefaults[AmpIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let value = jsonBool(section["cursorIntegration"]) {
            snapshot.managedUserDefaults[CursorIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let value = jsonBool(section["geminiIntegration"]) {
            snapshot.managedUserDefaults[GeminiIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let value = jsonBool(section["kiroIntegration"]) {
            snapshot.managedUserDefaults[KiroIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let raw = jsonString(section["kiroNotificationLevel"]) {
            if KiroIntegrationSettings.NotificationLevel(rawValue: raw) != nil {
                snapshot.managedUserDefaults[KiroIntegrationSettings.notificationLevelKey] = .string(raw)
            } else {
                logInvalid("automation.kiroNotificationLevel", sourcePath: sourcePath)
            }
        }
        if let value = jsonInt(section["portBase"]) {
            guard value > 0 else {
                logInvalid("automation.portBase", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AutomationSettings.portBaseKey] = .int(value)
        }
        if let value = jsonInt(section["portRange"]) {
            guard value > 0 else {
                logInvalid("automation.portRange", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[AutomationSettings.portRangeKey] = .int(value)
        }
    }

    private func parseBrowserSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["defaultSearchEngine"]) {
            guard let engine = BrowserSearchEngine(rawValue: raw) else {
                logInvalid("browser.defaultSearchEngine", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserSearchSettings.searchEngineKey] = .string(engine.rawValue)
        }
        if let raw = jsonString(section["customSearchEngineName"]) {
            snapshot.managedUserDefaults[BrowserSearchSettings.customSearchEngineNameKey] = .string(
                BrowserSearchSettings.normalizedCustomSearchEngineName(raw)
                    ?? BrowserSearchSettings.defaultCustomSearchEngineName
            )
        }
        if let raw = jsonString(section["customSearchEngineURLTemplate"]) {
            if BrowserSearchSettings.isValidSearchURLTemplate(raw) {
                snapshot.managedUserDefaults[BrowserSearchSettings.customSearchEngineURLTemplateKey] = .string(raw)
            } else {
                logInvalid("browser.customSearchEngineURLTemplate", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["showSearchSuggestions"]) {
            snapshot.managedUserDefaults[BrowserSearchSettings.searchSuggestionsEnabledKey] = .bool(value)
        }
        if let raw = jsonString(section["theme"]) {
            guard let mode = BrowserThemeMode(rawValue: raw) else {
                logInvalid("browser.theme", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserThemeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["discardHiddenWebViews"]) {
            snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.enabledKey] = .bool(value)
        }
        if let value = jsonDouble(section["hiddenWebViewDiscardDelaySeconds"]) {
            guard let delay = BrowserHiddenWebViewDiscardPolicy.resolvedHiddenDelay(value) else {
                logInvalid("browser.hiddenWebViewDiscardDelaySeconds", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey] = .double(delay)
        }
        if let value = jsonBool(section["openTerminalLinksInCmuxBrowser"]) {
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey] = .bool(value)
        }
        if let value = jsonBool(section["interceptTerminalOpenCommandInCmuxBrowser"]) {
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey] = .bool(value)
        }
        if let values = jsonStringArray(section["hostsToOpenInEmbeddedBrowser"]) {
            let normalized = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.browserHostWhitelistKey] = .string(normalized.joined(separator: "\n"))
        } else if section.keys.contains("hostsToOpenInEmbeddedBrowser") {
            logInvalid("browser.hostsToOpenInEmbeddedBrowser", sourcePath: sourcePath)
        }
        if let values = jsonStringArray(section["urlsToAlwaysOpenExternally"]) {
            let normalized = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            snapshot.managedUserDefaults[BrowserLinkOpenSettings.browserExternalOpenPatternsKey] = .string(
                normalized.joined(separator: "\n")
            )
        } else if section.keys.contains("urlsToAlwaysOpenExternally") {
            logInvalid("browser.urlsToAlwaysOpenExternally", sourcePath: sourcePath)
        }
        if let values = jsonStringArray(section["insecureHttpHostsAllowedInEmbeddedBrowser"]) {
            let normalized = values
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            snapshot.managedUserDefaults[BrowserInsecureHTTPSettings.allowlistKey] = .string(
                normalized.joined(separator: "\n")
            )
        } else if section.keys.contains("insecureHttpHostsAllowedInEmbeddedBrowser") {
            logInvalid("browser.insecureHttpHostsAllowedInEmbeddedBrowser", sourcePath: sourcePath)
        }
        if let value = jsonBool(section["showImportHintOnBlankTabs"]) {
            snapshot.managedUserDefaults[BrowserImportHintSettings.showOnBlankTabsKey] = .bool(value)
        }
        if let raw = jsonString(section["reactGrabVersion"]) {
            snapshot.managedUserDefaults[ReactGrabSettings.versionKey] = .string(raw)
        }
    }

    private func parseWorkspaceGroupsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["newWorkspacePlacement"]) {
            guard let placement = WorkspaceGroupNewPlacement(rawString: raw) else {
                logInvalid("workspaceGroups.newWorkspacePlacement", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[WorkspaceGroupNewWorkspacePlacementSettings.key] = .string(placement.rawValue)
        }
    }

    private func parseShortcutsSection(
        _ value: Any,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let section = value as? [String: Any] else {
            logInvalid("shortcuts", sourcePath: sourcePath)
            return
        }

        var bindings = section["bindings"] as? [String: Any] ?? [:]
        for (key, rawValue) in section where key != "bindings" && key != "showModifierHoldHints" {
            bindings[key] = rawValue
        }

        for (rawAction, rawBinding) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                cmuxSettingsFileStoreLogger.warning("ignoring unknown shortcut action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let shortcut = parseShortcutBindingValue(rawBinding, action: action) else {
                cmuxSettingsFileStoreLogger.warning("ignoring invalid shortcut binding for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.shortcuts[action] = shortcut
        }
    }

    private func parseShortcutBindingValue(
        _ rawValue: Any,
        action: KeyboardShortcutSettings.Action
    ) -> StoredShortcut? {
        let shortcut: StoredShortcut? = {
            if rawValue is NSNull { return .unbound }
            if let stroke = jsonString(rawValue) {
                return StoredShortcut.parseConfig(stroke, allowBareFirstStroke: action.allowsBareFirstStroke)
            }
            if let strokes = jsonStringArray(rawValue) {
                return strokes.isEmpty ? .unbound : StoredShortcut.parseConfig(
                    strokes: strokes,
                    allowBareFirstStroke: action.allowsBareFirstStroke
                )
            }
            // Object form written by the CmuxSettings package recorder (the
            // in-app Settings UI): { "first": { key, command, ... }, "second": { ... }? }.
            // The package serializes StoredShortcut as nested stroke objects, so
            // a rebinding made in Settings only reaches this store in that shape.
            // Decode it here so every action resolved through this store — most
            // visibly the system-wide Carbon hotkeys (globalSearch,
            // showHideAllWindows) — honors the rebinding instead of silently
            // dropping it and falling back to the built-in default.
            if let object = rawValue as? [String: Any] {
                return parseShortcutObjectForm(object, action: action)
            }
            return nil
        }()

        guard let shortcut else { return nil }
        // Settings-file parsing runs while the shared store may still be initializing.
        // Avoid the UI recorder's conflict lookup here because it reads the shared store.
        return action.normalizedSettingsFileShortcut(shortcut)
    }

    /// Decodes the nested-object binding the CmuxSettings package writes
    /// (`{ "first": { stroke }, "second": { stroke }? }`) into the app-target
    /// ``StoredShortcut``. An empty primary key is the package's explicit
    /// "unbound" marker. Returns `nil` when `first` is missing or malformed —
    /// and, to stay consistent with the string parser, when a present `second`
    /// stroke is malformed (a chord must not silently degrade to a single
    /// stroke) or when a bare first stroke is used by an action that requires a
    /// modifier.
    private func parseShortcutObjectForm(
        _ object: [String: Any],
        action: KeyboardShortcutSettings.Action
    ) -> StoredShortcut? {
        guard let firstValue = object["first"],
              let first = parseShortcutStrokeObject(firstValue) else {
            return nil
        }
        if first.key.isEmpty {
            return .unbound
        }
        // Mirror StoredShortcut.parseConfig(strokes:allowBareFirstStroke:): a
        // bare first stroke is only valid for actions that opt into it, or for
        // the space key.
        guard action.allowsBareFirstStroke || !first.modifierFlags.isEmpty || first.key == "space" else {
            return nil
        }
        let second: ShortcutStroke?
        if let secondValue = object["second"], !(secondValue is NSNull) {
            // A present-but-malformed second stroke invalidates the whole
            // binding rather than silently dropping the chord half.
            guard let parsedSecond = parseShortcutStrokeObject(secondValue) else {
                return nil
            }
            second = parsedSecond
        } else {
            second = nil
        }
        return StoredShortcut(first: first, second: second)
    }

    private func parseShortcutStrokeObject(_ rawValue: Any) -> ShortcutStroke? {
        if rawValue is NSNull { return nil }
        guard let dict = rawValue as? [String: Any],
              let key = jsonString(dict["key"]) else {
            return nil
        }
        // An out-of-range keyCode is a corrupt binding, not a key to silently
        // wrap into a valid UInt16 (which would re-target a different key).
        let keyCode: UInt16?
        if let rawKeyCode = jsonInt(dict["keyCode"]) {
            guard let value = UInt16(exactly: rawKeyCode) else { return nil }
            keyCode = value
        } else {
            keyCode = nil
        }
        return ShortcutStroke(
            key: key,
            command: jsonBool(dict["command"]) ?? false,
            shift: jsonBool(dict["shift"]) ?? false,
            option: jsonBool(dict["option"]) ?? false,
            control: jsonBool(dict["control"]) ?? false,
            keyCode: keyCode
        )
    }

    private func parseNullableHex(
        _ rawValue: Any?,
        path: String,
        sourcePath: String
    ) -> String?? {
        if rawValue is NSNull {
            return .some(nil)
        }
        guard let raw = jsonString(rawValue),
              let normalized = WorkspaceTabColorSettings.normalizedHex(raw) else {
            logInvalid(path, sourcePath: sourcePath)
            return nil
        }
        return .some(normalized)
    }

    private func logInvalid(_ path: String, sourcePath: String) {
        cmuxSettingsFileStoreLogger.warning("ignoring invalid setting '\(path, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        rawValue as? String
    }

    private func jsonBool(_ rawValue: Any?) -> Bool? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private func jsonInt(_ rawValue: Any?) -> Int? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let doubleValue = number.doubleValue
        guard doubleValue.rounded() == doubleValue else { return nil }
        return number.intValue
    }

    private func jsonDouble(_ rawValue: Any?) -> Double? {
        guard let number = rawValue as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue
    }

    private func jsonStringArray(_ rawValue: Any?) -> [String]? {
        guard let values = rawValue as? [Any] else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(values.count)
        for value in values {
            guard let string = value as? String else { return nil }
            strings.append(string)
        }
        return strings
    }

}
