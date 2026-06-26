import CMUXAgentLaunch
import struct CmuxBrowser.BrowserThemeSettings
import CmuxSettings
import Foundation
import os

nonisolated private let settingsFileParserLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

/// Stateless parser for cmux settings JSON roots.
///
/// Projects a decoded `cmux.json` / `settings.json` JSON object into a
/// ``ResolvedSettingsSnapshot`` of managed `UserDefaults` values, custom
/// settings, keyboard-shortcut overrides, and `when`-clause overrides. It holds
/// no paths and touches no filesystem: ``SettingsFileReader`` owns the file I/O
/// (reading bytes, JSONC preprocessing, JSON decoding) and calls
/// ``parseSettingsFile(root:sourcePath:)`` once per source file.
struct SettingsFileParser {
    private let projection = SettingsFileProjectionEngine()

    func parseSettingsFile(root: [String: Any], sourcePath: String) -> ResolvedSettingsSnapshot {
        let schemaVersion = jsonInt(root["schemaVersion"]) ?? 1
        if schemaVersion > CmuxSettingsFileSchema.current.version {
            settingsFileParserLogger.warning("\(sourcePath, privacy: .private(mask: .hash)) uses future schemaVersion \(schemaVersion, privacy: .private(mask: .hash)); parsing known fields only")
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
        if let fileExplorerSection = root["fileExplorer"] as? [String: Any] {
            parseFileExplorerSection(fileExplorerSection, sourcePath: sourcePath, snapshot: &snapshot)
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
            snapshot.managedUserDefaults[AppCatalogSection().language.userDefaultsKey] = .string(language.rawValue)
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
            snapshot.managedUserDefaults[AppCatalogSection().appIcon.userDefaultsKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["menuBarOnly"]) {
            snapshot.managedUserDefaults[MenuBarOnlySettings.menuBarOnlyKey] = .bool(value)
            if value {
                snapshot.managedUserDefaults[MenuBarOnlySettings.explicitEnableKey] = .bool(true)
            }
        }
        if let raw = jsonString(section["windowTitleTemplate"]) { snapshot.managedUserDefaults[WindowTitleTemplate.userDefaultsKey] = .string(raw) } else if section.keys.contains("windowTitleTemplate") { logInvalid("app.windowTitleTemplate", sourcePath: sourcePath) }
        if let raw = jsonString(section["newWorkspacePlacement"]) {
            guard let placement = WorkspacePlacement(rawValue: raw) else {
                logInvalid("app.newWorkspacePlacement", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[SettingCatalog().app.newWorkspacePlacement.userDefaultsKey] = .string(placement.rawValue)
        }
        if let raw = jsonString(section["forkConversationDefaultDestination"]) {
            if let destination = AgentConversationForkDestination(rawValue: raw) {
                snapshot.managedUserDefaults[AgentConversationForkDestination.defaultDestinationDefaultsKey] = .string(destination.rawValue)
            } else {
                logInvalid("app.forkConversationDefaultDestination", sourcePath: sourcePath)
            }
        }
        projection.applyBooleanSettings(AppSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        projection.applyStringSettings(AppSettingsFileMapping.stringSettings, from: section, into: &snapshot)
        if let value = jsonBool(section["minimalMode"]) {
            let mode = value ? WorkspacePresentationModeSettings.Mode.minimal : .standard
            snapshot.managedUserDefaults[WorkspacePresentationModeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonBool(section["keepWorkspaceOpenWhenClosingLastSurface"]) {
            snapshot.managedUserDefaults[SettingCatalog().app.keepWorkspaceOpenWhenClosingLastSurface.userDefaultsKey] = .bool(!value)
        }
        var parsedConfirmQuitMode: ConfirmQuitMode?
        let confirmQuitKey = AppCatalogSection().confirmQuitMode.userDefaultsKey
        let warnBeforeQuitKey = AppCatalogSection().warnBeforeQuit.userDefaultsKey
        if let raw = jsonString(section["confirmQuit"]) {
            if let mode = ConfirmQuitMode(rawValue: raw) {
                parsedConfirmQuitMode = mode
                snapshot.managedUserDefaults[confirmQuitKey] = .string(mode.rawValue)
            } else {
                logInvalid("app.confirmQuit", sourcePath: sourcePath)
            }
        }
        if let value = jsonBool(section["warnBeforeQuit"]) {
            snapshot.managedUserDefaults[warnBeforeQuitKey] = .bool(value)
            if parsedConfirmQuitMode == nil {
                let mode: ConfirmQuitMode = value ? .always : .never
                snapshot.managedUserDefaults[confirmQuitKey] = .string(mode.rawValue)
                snapshot.legacyDerivedManagedUserDefaultKeys.insert(confirmQuitKey)
            }
        }
    }

    private func parseNotificationsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        projection.applyBooleanSettings(NotificationSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        if let raw = jsonString(section["sound"]) {
            let allowed = Set(NotificationSoundSettings.systemSounds.map(\.value))
            guard allowed.contains(raw) else {
                logInvalid("notifications.sound", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[NotificationSoundSettings.key] = .string(raw)
        }
        projection.applyStringSettings(NotificationSettingsFileMapping.stringSettings, from: section, into: &snapshot)
    }

    private func parseTerminalSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        projection.applyBooleanSettings(TerminalSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)

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

        if let rawRendererRealization = section["rendererRealization"],
           let rendererRealization = rawRendererRealization as? [String: Any] {
            if let value = jsonBool(rendererRealization["enabled"]) {
                snapshot.managedUserDefaults[RendererRealizationSettings.enabledKey] = .bool(value)
            } else if rendererRealization.keys.contains("enabled") {
                logInvalid("terminal.rendererRealization.enabled", sourcePath: sourcePath)
            }
            if let value = jsonInt(rendererRealization["idleSeconds"]) {
                snapshot.managedUserDefaults[RendererRealizationSettings.idleSecondsKey] = .double(
                    RendererRealizationSettings.sanitizedIdleSeconds(TimeInterval(value))
                )
            } else if rendererRealization.keys.contains("idleSeconds") {
                logInvalid("terminal.rendererRealization.idleSeconds", sourcePath: sourcePath)
            }
            if let value = jsonInt(rendererRealization["maxWarmRenderers"]) {
                snapshot.managedUserDefaults[RendererRealizationSettings.maxWarmRenderersKey] = .int(
                    RendererRealizationSettings.sanitizedMaxWarmRenderers(value)
                )
            } else if rendererRealization.keys.contains("maxWarmRenderers") {
                logInvalid("terminal.rendererRealization.maxWarmRenderers", sourcePath: sourcePath)
            }
        } else if section.keys.contains("rendererRealization") {
            logInvalid("terminal.rendererRealization", sourcePath: sourcePath)
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

    private func parseFileExplorerSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["doubleClickAction"]) {
            if let action = FileExplorerDoubleClickAction(rawValue: raw) {
                snapshot.managedUserDefaults[FileExplorerDoubleClickActionSettings.key] = .string(action.rawValue)
            } else {
                logInvalid("fileExplorer.doubleClickAction", sourcePath: sourcePath)
            }
        } else if section.keys.contains("doubleClickAction") {
            logInvalid("fileExplorer.doubleClickAction", sourcePath: sourcePath)
        }
    }

    private func parseSidebarSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        for setting in SidebarSettingsFileMapping.booleanSettings {
            if let value = jsonBool(section[setting.jsonKey]) {
                snapshot.managedUserDefaults[setting.defaultsKey] = .bool(value)
            }
        }

        if let raw = jsonString(section["branchLayout"]) {
            if let value = SidebarSettingsFileMapping.branchLayoutStoredValue(raw) {
                snapshot.managedUserDefaults[
                    SidebarCatalogSection().branchVerticalLayout.userDefaultsKey
                ] = .bool(value)
            } else {
                logInvalid("sidebar.branchLayout", sourcePath: sourcePath)
            }
        }

        if let value = jsonDouble(section[RightSidebarWidthSettings.jsonKey]), value > 0 {
            snapshot.managedUserDefaults[RightSidebarWidthSettings.maxWidthKey] = .double(
                RightSidebarWidthSettings().clampedSettingsEditorMaximumWidth(value)
            )
        } else if section.keys.contains(RightSidebarWidthSettings.jsonKey) {
            logInvalid(RightSidebarWidthSettings.settingsPath, sourcePath: sourcePath)
        }
    }

    private func parseWorkspaceColorsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let raw = jsonString(section["indicatorStyle"]) {
            let indicatorKey = SettingCatalog().workspaceColors.indicatorStyle
            let normalized = (WorkspaceIndicatorStyle.decodeFromJSON(raw) ?? indicatorKey.defaultValue).rawValue
            let accepted = Set(WorkspaceIndicatorStyle.allCases.map(\.rawValue)).union([
                "rail", "border", "wash", "lift", "typography", "washRail", "blueWashColorRail",
            ])
            guard accepted.contains(raw) else {
                logInvalid("workspaceColors.indicatorStyle", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[indicatorKey.userDefaultsKey] = .string(normalized)
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
                    settingsFileParserLogger.warning("ignoring empty workspace color name in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    settingsFileParserLogger.warning("ignoring invalid workspace color '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
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
                    settingsFileParserLogger.warning("ignoring unknown workspace color '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    settingsFileParserLogger.warning("ignoring invalid workspace color override '\(name, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
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
        projection.applyBooleanSettings(AutomationSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        projection.applyStringSettings(AutomationSettingsFileMapping.stringSettings, from: section, into: &snapshot)
        if let raw = jsonString(section["kiroNotificationLevel"]) {
            if KiroNotificationLevel(rawValue: raw) != nil {
                snapshot.managedUserDefaults[IntegrationsCatalogSection().kiroNotificationLevel.userDefaultsKey] = .string(raw)
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
        let browserSearchSettings = BrowserSearchSettingsStore()

        if let raw = jsonString(section["defaultSearchEngine"]) {
            guard let engine = BrowserSearchEngine(rawValue: raw) else {
                logInvalid("browser.defaultSearchEngine", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserSearchSettingsStore.searchEngineKey] = .string(engine.rawValue)
        }
        if let raw = jsonString(section["customSearchEngineName"]) {
            snapshot.managedUserDefaults[BrowserSearchSettingsStore.customSearchEngineNameKey] = .string(
                browserSearchSettings.normalizedCustomSearchEngineName(raw)
                    ?? BrowserSearchSettingsStore.defaultCustomSearchEngineName
            )
        }
        if let raw = jsonString(section["customSearchEngineURLTemplate"]) {
            if browserSearchSettings.isValidSearchURLTemplate(raw) {
                snapshot.managedUserDefaults[BrowserSearchSettingsStore.customSearchEngineURLTemplateKey] = .string(raw)
            } else {
                logInvalid("browser.customSearchEngineURLTemplate", sourcePath: sourcePath)
            }
        }
        projection.applyBooleanSettings(BrowserSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        projection.applyStringSettings(BrowserSettingsFileMapping.stringSettings, from: section, into: &snapshot)
        if let raw = jsonString(section["theme"]) {
            guard let mode = BrowserThemeMode(rawValue: raw) else {
                logInvalid("browser.theme", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserThemeSettings.modeKey] = .string(mode.rawValue)
        }
        if let value = jsonDouble(section["hiddenWebViewDiscardDelaySeconds"]) {
            guard let delay = BrowserHiddenWebViewDiscardPolicy.resolvedHiddenDelay(value) else {
                logInvalid("browser.hiddenWebViewDiscardDelaySeconds", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey] = .double(delay)
        }
        projection.applyNormalizedStringArraySettings(BrowserSettingsFileMapping.stringArraySettings, from: section, sourcePath: sourcePath, into: &snapshot)
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
            snapshot.managedUserDefaults[SettingCatalog().workspaceGroups.newWorkspacePlacement.userDefaultsKey] = .string(placement.rawValue)
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
        if let value = jsonBool(section["showModifierHoldHints"]) {
            snapshot.managedUserDefaults[SettingCatalog().shortcuts.showModifierHoldHints.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("showModifierHoldHints") {
            logInvalid("shortcuts.showModifierHoldHints", sourcePath: sourcePath)
        }
        for (key, rawValue) in section where key != "bindings" && key != "showModifierHoldHints" && key != "when" {
            bindings[key] = rawValue
        }

        for (rawAction, rawBinding) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                settingsFileParserLogger.warning("ignoring unknown shortcut action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let shortcut = StoredShortcut.parseSettingsFileBinding(rawBinding, action: action) else {
                settingsFileParserLogger.warning("ignoring invalid shortcut binding for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.shortcuts[action] = shortcut
        }

        parseShortcutWhenClauses(section["when"], sourcePath: sourcePath, snapshot: &snapshot)
    }

    /// Parses the optional `shortcuts.when` map — `{ "<actionId>": "<predicate>" }`
    /// — into per-action ``ShortcutWhenClause`` overrides. A binding's `when`
    /// clause gates it to a focus context, letting the same keystroke drive
    /// different actions in different contexts (e.g. `⌃1` selects a workspace
    /// unless the sidebar is focused). Invalid entries are logged and skipped.
    private func parseShortcutWhenClauses(
        _ rawValue: Any?,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let rawValue else { return }
        guard let whenSection = rawValue as? [String: Any] else {
            logInvalid("shortcuts.when", sourcePath: sourcePath)
            return
        }
        for (rawAction, rawClause) in whenSection {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                settingsFileParserLogger.warning("ignoring shortcuts.when for unknown action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let expression = jsonString(rawClause),
                  let clause = ShortcutWhenClause.parse(expression) else {
                settingsFileParserLogger.warning("ignoring invalid shortcuts.when clause for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.whenClauses[action] = clause
        }
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

    // The domain-agnostic projection engine (table-driven apply, invalid-setting
    // logging, JSON scalar coercion) lives in `CmuxSettings`. The parser holds one
    // instance; the per-domain methods forward the shared `logInvalid`/`json*`
    // helpers to it so their call sites stay unchanged.
    private func logInvalid(_ path: String, sourcePath: String) {
        projection.logInvalid(path, sourcePath: sourcePath)
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        projection.jsonString(rawValue)
    }

    private func jsonBool(_ rawValue: Any?) -> Bool? {
        projection.jsonBool(rawValue)
    }

    private func jsonInt(_ rawValue: Any?) -> Int? {
        projection.jsonInt(rawValue)
    }

    private func jsonDouble(_ rawValue: Any?) -> Double? {
        projection.jsonDouble(rawValue)
    }

    private func jsonStringArray(_ rawValue: Any?) -> [String]? {
        projection.jsonStringArray(rawValue)
    }
}
