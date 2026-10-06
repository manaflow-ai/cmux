import CmuxSettings
import Foundation

/// Settings-file section parsers for file editor, file explorer, agent messages, markdown, mobile, and sidebar workspace-todo options, extracted from `KeyboardShortcutSettingsFileStore.swift`, which sits at its file-length budget.
extension CmuxSettingsFileStore {
    /// Parses canonical beta and integration sections that share legacy
    /// UserDefaults storage with the classic settings importer.
    func parseClassicCatalogSections(
        _ root: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let integrations = root["integrations"] as? [String: Any] {
            parseIntegrationsSection(integrations, sourcePath: sourcePath, snapshot: &snapshot)
        } else if root.keys.contains("integrations") {
            logInvalid("integrations", sourcePath: sourcePath)
        }

        parseBetaToggle(
            root["rightSidebar"] as? [String: Any],
            nestedPath: ["beta", "feed", "enabled"],
            setting: SettingCatalog().betaFeatures.rightSidebarFeed,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseBetaToggle(
            root["extensions"] as? [String: Any],
            nestedPath: ["beta", "enabled"],
            setting: SettingCatalog().betaFeatures.extensions,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseBetaToggle(
            root["customSidebars"] as? [String: Any],
            nestedPath: ["beta", "enabled"],
            setting: SettingCatalog().betaFeatures.customSidebars,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseBetaToggle(
            root["cloud"] as? [String: Any],
            nestedPath: ["beta", "machines", "enabled"],
            setting: SettingCatalog().betaFeatures.cloudMachines,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseBetaToggle(
            root["remoteTmux"] as? [String: Any],
            nestedPath: ["beta", "enabled"],
            setting: SettingCatalog().betaFeatures.remoteTmux,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseBetaToggle(
            root["remoteTmux"] as? [String: Any],
            nestedPath: ["multiplexer", "beta", "enabled"],
            setting: SettingCatalog().betaFeatures.remoteTmuxMultiplexer,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
    }

    private func parseIntegrationsSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        parseIntegrationProvider(
            section["claudeCode"],
            providerPath: "integrations.claudeCode",
            hooksKey: SettingCatalog().integrations.claudeCodeHooksEnabled,
            customPathKey: SettingCatalog().integrations.claudeCodeCustomClaudePath,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["codex"],
            providerPath: "integrations.codex",
            hooksKey: SettingCatalog().integrations.codexHooksEnabled,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["pi"],
            providerPath: "integrations.pi",
            hooksKey: SettingCatalog().integrations.piHooksEnabled,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["amp"],
            providerPath: "integrations.amp",
            hooksKey: SettingCatalog().integrations.ampHooksEnabled,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["cursor"],
            providerPath: "integrations.cursor",
            hooksKey: SettingCatalog().integrations.cursorHooksEnabled,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["gemini"],
            providerPath: "integrations.gemini",
            hooksKey: SettingCatalog().integrations.geminiHooksEnabled,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseIntegrationProvider(
            section["kiro"],
            providerPath: "integrations.kiro",
            hooksKey: SettingCatalog().integrations.kiroHooksEnabled,
            notificationLevelKey: SettingCatalog().integrations.kiroNotificationLevel,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )

        if let ripgrep = section["ripgrep"] as? [String: Any] {
            if let raw = jsonString(ripgrep["customBinaryPath"]) {
                snapshot.managedUserDefaults[
                    SettingCatalog().integrations.ripgrepCustomBinaryPath.userDefaultsKey
                ] = .string(raw)
            } else if ripgrep.keys.contains("customBinaryPath") {
                logInvalid("integrations.ripgrep.customBinaryPath", sourcePath: sourcePath)
            }
        } else if section.keys.contains("ripgrep") {
            logInvalid("integrations.ripgrep", sourcePath: sourcePath)
        }

        if let value = jsonBool(section["suppressSubagentNotifications"]) {
            snapshot.managedUserDefaults[
                SettingCatalog().integrations.suppressSubagentNotifications.userDefaultsKey
            ] = .bool(value)
        } else if section.keys.contains("suppressSubagentNotifications") {
            logInvalid("integrations.suppressSubagentNotifications", sourcePath: sourcePath)
        }
    }

    private func parseIntegrationProvider(
        _ rawValue: Any?,
        providerPath: String,
        hooksKey: DefaultsKey<Bool>,
        customPathKey: DefaultsKey<String>? = nil,
        notificationLevelKey: DefaultsKey<String>? = nil,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let rawValue else { return }
        guard let provider = rawValue as? [String: Any] else {
            logInvalid(providerPath, sourcePath: sourcePath)
            return
        }
        if let value = jsonBool(provider["hooksEnabled"]) {
            snapshot.managedUserDefaults[hooksKey.userDefaultsKey] = .bool(value)
        } else if provider.keys.contains("hooksEnabled") {
            logInvalid("\(providerPath).hooksEnabled", sourcePath: sourcePath)
        }
        if let customPathKey {
            if let raw = jsonString(provider["customClaudePath"]) {
                snapshot.managedUserDefaults[customPathKey.userDefaultsKey] = .string(raw)
            } else if provider.keys.contains("customClaudePath") {
                logInvalid("\(providerPath).customClaudePath", sourcePath: sourcePath)
            }
        }
        if let notificationLevelKey {
            if let raw = jsonString(provider["notificationLevel"]), KiroNotificationLevel(rawValue: raw) != nil {
                snapshot.managedUserDefaults[notificationLevelKey.userDefaultsKey] = .string(raw)
            } else if provider.keys.contains("notificationLevel") {
                logInvalid("\(providerPath).notificationLevel", sourcePath: sourcePath)
            }
        }
    }

    private func parseBetaToggle(
        _ section: [String: Any]?,
        nestedPath: [String],
        setting: DefaultsKey<Bool>,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let section else { return }
        var current: Any = section
        for component in nestedPath.dropLast() {
            guard let object = current as? [String: Any], let next = object[component] else {
                return
            }
            current = next
        }
        guard let object = current as? [String: Any], let finalKey = nestedPath.last else { return }
        if let value = jsonBool(object[finalKey]) {
            snapshot.managedUserDefaults[setting.userDefaultsKey] = .bool(value)
        } else if object.keys.contains(finalKey) {
            logInvalid(setting.id, sourcePath: sourcePath)
        }
    }

    func parseCanonicalTerminalSettings(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let rawTitleUpdates = section["titleUpdates"],
           let titleUpdates = rawTitleUpdates as? [String: Any] {
            if let rawCoalescing = titleUpdates["coalescing"],
               let coalescing = rawCoalescing as? [String: Any] {
                let titleSettings = SettingCatalog().terminal
                if let value = jsonBool(coalescing["enabled"]) {
                    snapshot.managedUserDefaults[titleSettings.titleUpdateCoalescingEnabled.userDefaultsKey] = .bool(value)
                } else if coalescing.keys.contains("enabled") {
                    logInvalid(titleSettings.titleUpdateCoalescingEnabled.id, sourcePath: sourcePath)
                }
                if let value = jsonInt(coalescing["delayMilliseconds"]),
                   (PanelTitleUpdateCoalescingSettings.minimumDelayMilliseconds...PanelTitleUpdateCoalescingSettings.maximumDelayMilliseconds).contains(value) {
                    snapshot.managedUserDefaults[titleSettings.titleUpdateCoalescingMilliseconds.userDefaultsKey] = .int(value)
                } else if coalescing.keys.contains("delayMilliseconds") {
                    logInvalid(titleSettings.titleUpdateCoalescingMilliseconds.id, sourcePath: sourcePath)
                }
            } else if titleUpdates.keys.contains("coalescing") {
                logInvalid("terminal.titleUpdates.coalescing", sourcePath: sourcePath)
            }
            if let value = jsonBool(titleUpdates["diagnostics"]) {
                snapshot.managedUserDefaults[SettingCatalog().terminal.titleUpdateDiagnostics.userDefaultsKey] = .bool(value)
            } else if titleUpdates.keys.contains("diagnostics") {
                logInvalid(SettingCatalog().terminal.titleUpdateDiagnostics.id, sourcePath: sourcePath)
            }
        } else if section.keys.contains("titleUpdates") {
            logInvalid("terminal.titleUpdates", sourcePath: sourcePath)
        }

        if let rawGuardrail = section["runawayMemoryGuardrail"],
           let guardrail = rawGuardrail as? [String: Any] {
            let guardrailSettings = SettingCatalog().terminal
            if let value = jsonBool(guardrail["enabled"]) {
                snapshot.managedUserDefaults[guardrailSettings.runawayMemoryGuardrailEnabled.userDefaultsKey] = .bool(value)
            } else if guardrail.keys.contains("enabled") {
                logInvalid(guardrailSettings.runawayMemoryGuardrailEnabled.id, sourcePath: sourcePath)
            }
            if let value = jsonDouble(guardrail["thresholdGB"]), value.isFinite, (1...256).contains(value) {
                snapshot.managedUserDefaults[guardrailSettings.runawayMemoryGuardrailThresholdGB.userDefaultsKey] = .double(value)
            } else if guardrail.keys.contains("thresholdGB") {
                logInvalid(guardrailSettings.runawayMemoryGuardrailThresholdGB.id, sourcePath: sourcePath)
            }
        } else if section.keys.contains("runawayMemoryGuardrail") {
            logInvalid("terminal.runawayMemoryGuardrail", sourcePath: sourcePath)
        }
    }

    func parseCanonicalSidebarSettings(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["branchVerticalLayout"]) {
            snapshot.managedUserDefaults[SidebarCatalogSection().branchVerticalLayout.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("branchVerticalLayout") {
            logInvalid(SidebarCatalogSection().branchVerticalLayout.id, sourcePath: sourcePath)
        }
        if let raw = jsonString(section["activeTabIndicatorStyle"]),
           let indicator = WorkspaceIndicatorStyle.decodeFromJSON(raw) {
            snapshot.managedUserDefaults[SettingCatalog().workspaceColors.indicatorStyle.userDefaultsKey] = .string(indicator.rawValue)
        } else if section.keys.contains("activeTabIndicatorStyle") {
            logInvalid(SidebarCatalogSection().activeTabIndicatorStyle.id, sourcePath: sourcePath)
        }
        if section.keys.contains("selectionColor"),
           let value = parseCanonicalNullableHex(
               section["selectionColor"],
               path: SidebarCatalogSection().selectionColorHex.id,
               sourcePath: sourcePath
           ) {
            snapshot.managedUserDefaults[SidebarCatalogSection().selectionColorHex.userDefaultsKey] = .nullableString(value)
        }
        if section.keys.contains("notificationBadgeColor"),
           let value = parseCanonicalNullableHex(
               section["notificationBadgeColor"],
               path: SidebarCatalogSection().notificationBadgeColorHex.id,
               sourcePath: sourcePath
           ) {
            snapshot.managedUserDefaults[SidebarCatalogSection().notificationBadgeColorHex.userDefaultsKey] = .nullableString(value)
        }
    }

    private func parseCanonicalNullableHex(
        _ rawValue: Any?,
        path: String,
        sourcePath: String
    ) -> String?? {
        if rawValue is NSNull { return .some(nil) }
        guard let raw = jsonString(rawValue),
              let normalized = WorkspaceTabColorSettings.normalizedHex(raw) else {
            logInvalid(path, sourcePath: sourcePath)
            return nil
        }
        return .some(normalized)
    }

    func parseFileEditorSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let fileEditorSettings = FilePreviewEditorSettings(defaults: .standard)
        if let value = jsonBool(section["wordWrap"]) {
            snapshot.managedUserDefaults[FilePreviewWordWrapSettings.key] = .bool(value)
        } else if section.keys.contains("wordWrap") {
            logInvalid("fileEditor.wordWrap", sourcePath: sourcePath)
        }
        parseFileEditorBool(
            section,
            jsonKey: "syntaxHighlighting",
            defaultsKey: fileEditorSettings.catalog.syntaxHighlighting.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseFileEditorBool(
            section,
            jsonKey: "lineNumbers",
            defaultsKey: fileEditorSettings.catalog.lineNumbers.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseFileEditorBool(
            section,
            jsonKey: "indentGuides",
            defaultsKey: fileEditorSettings.catalog.indentGuides.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        parseFileEditorBool(
            section,
            jsonKey: "currentLineHighlight",
            defaultsKey: fileEditorSettings.catalog.currentLineHighlight.userDefaultsKey,
            sourcePath: sourcePath,
            snapshot: &snapshot
        )
        if let value = jsonInt(section["tabWidth"]) {
            if fileEditorSettings.catalog.tabWidthRange.contains(value) {
                snapshot.managedUserDefaults[fileEditorSettings.catalog.tabWidth.userDefaultsKey] = .int(value)
            } else {
                logInvalid("fileEditor.tabWidth", sourcePath: sourcePath)
            }
        } else if section.keys.contains("tabWidth") {
            logInvalid("fileEditor.tabWidth", sourcePath: sourcePath)
        }
    }

    private func parseFileEditorBool(
        _ section: [String: Any],
        jsonKey: String,
        defaultsKey: String,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section[jsonKey]) {
            snapshot.managedUserDefaults[defaultsKey] = .bool(value)
        } else if section.keys.contains(jsonKey) {
            logInvalid("fileEditor.\(jsonKey)", sourcePath: sourcePath)
        }
    }

    func parseFileExplorerSection(
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

    /// `agentMessages.enabled`, the app-wide switch for agent messages.
    func parseAgentMessagesSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["enabled"]) {
            snapshot.managedUserDefaults[AgentMessagesCatalogSection().enabled.userDefaultsKey] = .bool(value)
        } else if section.keys.contains("enabled") {
            logInvalid("agentMessages.enabled", sourcePath: sourcePath)
        }
    }

    func parseSidebarWorkspaceTodosBeta(
        _ beta: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        let betaKeys = BetaFeaturesCatalogSection()
        if let rawConversations = beta["conversations"], let conversations = rawConversations as? [String: Any] {
            if let enabled = jsonBool(conversations["enabled"]) {
                snapshot.managedUserDefaults[
                    betaKeys.conversationSidebar.userDefaultsKey
                ] = .bool(enabled)
            } else if conversations.keys.contains("enabled") {
                logInvalid("sidebar.beta.conversations.enabled", sourcePath: sourcePath)
            }
        } else if beta.keys.contains("conversations") {
            logInvalid("sidebar.beta.conversations", sourcePath: sourcePath)
        }

        if let rawTodos = beta["workspaceTodos"], let todos = rawTodos as? [String: Any] {
            if let controls = todos["controls"] as? [String: Any] {
                if let enabled = jsonBool(controls["enabled"]) {
                    snapshot.managedUserDefaults[
                        betaKeys.workspaceTodoControls.userDefaultsKey
                    ] = .bool(enabled)
                } else if controls.keys.contains("enabled") {
                    logInvalid("sidebar.beta.workspaceTodos.controls.enabled", sourcePath: sourcePath)
                }
            } else if todos.keys.contains("controls") {
                logInvalid("sidebar.beta.workspaceTodos.controls", sourcePath: sourcePath)
            }
            if let raw = jsonString(todos["checklistStyle"]) {
                if let style = WorkspaceTodoChecklistStyle.decodeFromJSON(raw) {
                    snapshot.managedUserDefaults[
                        betaKeys.workspaceTodosChecklistStyle.userDefaultsKey
                    ] = .string(style.rawValue)
                } else {
                    logInvalid("sidebar.beta.workspaceTodos.checklistStyle", sourcePath: sourcePath)
                }
            } else if todos.keys.contains("checklistStyle") {
                logInvalid("sidebar.beta.workspaceTodos.checklistStyle", sourcePath: sourcePath)
            }
        } else if beta.keys.contains("workspaceTodos") {
            logInvalid("sidebar.beta.workspaceTodos", sourcePath: sourcePath)
        }
    }

    func parseMarkdownSection(
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

    func parseMobileSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if section.keys.contains("artifactFolderAccess") {
            if let raw = jsonString(section["artifactFolderAccess"]),
               let value = MobileArtifactFolderAccess(rawValue: raw) {
                let key = SettingCatalog().mobile.artifactFolderAccess
                snapshot.managedUserDefaults[key.userDefaultsKey] = .string(value.rawValue)
            } else {
                logInvalid("mobile.artifactFolderAccess", sourcePath: sourcePath)
            }
        }
        if section.keys.contains("browserTunnel") {
            guard let tunnel = section["browserTunnel"] as? [String: Any] else {
                logInvalid("mobile.browserTunnel", sourcePath: sourcePath)
                return
            }
            if let value = jsonBool(tunnel["allowOtherHosts"]) {
                let key = SettingCatalog().mobile.browserTunnelAllowOtherHosts
                snapshot.managedUserDefaults[key.userDefaultsKey] = .bool(value)
            } else if tunnel.keys.contains("allowOtherHosts") {
                logInvalid("mobile.browserTunnel.allowOtherHosts", sourcePath: sourcePath)
            }
        }
    }
}
