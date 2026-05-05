import Foundation

enum CmuxSettingsJSONPersistence {
    static func currentSettingsJSONValuesFromUserDefaults(
        defaults: UserDefaults = .standard
    ) -> [String: ManagedSettingsValue] {
        var values: [String: ManagedSettingsValue] = [
            "app.language": .string(stringValue(
                LanguageSettings.languageKey,
                defaultValue: LanguageSettings.defaultLanguage.rawValue,
                defaults: defaults
            )),
            "app.appearance": .string(stringValue(
                AppearanceSettings.appearanceModeKey,
                defaultValue: AppearanceSettings.defaultMode.rawValue,
                defaults: defaults
            )),
            "app.appIcon": .string(stringValue(
                AppIconSettings.modeKey,
                defaultValue: AppIconSettings.defaultMode.rawValue,
                defaults: defaults
            )),
            "app.menuBarOnly": .bool(boolValue(
                MenuBarOnlySettings.menuBarOnlyKey,
                defaultValue: MenuBarOnlySettings.defaultMenuBarOnly,
                defaults: defaults
            )),
            "app.newWorkspacePlacement": .string(stringValue(
                WorkspacePlacementSettings.placementKey,
                defaultValue: WorkspacePlacementSettings.defaultPlacement.rawValue,
                defaults: defaults
            )),
            "app.minimalMode": .bool(
                stringValue(
                    WorkspacePresentationModeSettings.modeKey,
                    defaultValue: WorkspacePresentationModeSettings.defaultMode.rawValue,
                    defaults: defaults
                ) == WorkspacePresentationModeSettings.Mode.minimal.rawValue
            ),
            "app.keepWorkspaceOpenWhenClosingLastSurface": .bool(!boolValue(
                LastSurfaceCloseShortcutSettings.key,
                defaultValue: LastSurfaceCloseShortcutSettings.defaultValue,
                defaults: defaults
            )),
            "app.focusPaneOnFirstClick": .bool(boolValue(
                PaneFirstClickFocusSettings.enabledKey,
                defaultValue: PaneFirstClickFocusSettings.defaultEnabled,
                defaults: defaults
            )),
            "app.preferredEditor": .string(stringValue(
                PreferredEditorSettings.key,
                defaultValue: "",
                defaults: defaults
            )),
            "app.openMarkdownInCmuxViewer": .bool(boolValue(
                CmdClickMarkdownRouteSettings.key,
                defaultValue: CmdClickMarkdownRouteSettings.defaultValue,
                defaults: defaults
            )),
            "app.iMessageMode": .bool(boolValue(
                IMessageModeSettings.key,
                defaultValue: IMessageModeSettings.defaultValue,
                defaults: defaults
            )),
            "app.reorderOnNotification": .bool(boolValue(
                WorkspaceAutoReorderSettings.key,
                defaultValue: WorkspaceAutoReorderSettings.defaultValue,
                defaults: defaults
            )),
            "app.sendAnonymousTelemetry": .bool(boolValue(
                TelemetrySettings.sendAnonymousTelemetryKey,
                defaultValue: TelemetrySettings.defaultSendAnonymousTelemetry,
                defaults: defaults
            )),
            "app.warnBeforeQuit": .bool(boolValue(
                QuitWarningSettings.warnBeforeQuitKey,
                defaultValue: QuitWarningSettings.defaultWarnBeforeQuit,
                defaults: defaults
            )),
            "app.renameSelectsExistingName": .bool(boolValue(
                CommandPaletteRenameSelectionSettings.selectAllOnFocusKey,
                defaultValue: CommandPaletteRenameSelectionSettings.defaultSelectAllOnFocus,
                defaults: defaults
            )),
            "app.commandPaletteSearchesAllSurfaces": .bool(boolValue(
                CommandPaletteSwitcherSearchSettings.searchAllSurfacesKey,
                defaultValue: CommandPaletteSwitcherSearchSettings.defaultSearchAllSurfaces,
                defaults: defaults
            )),
            "terminal.showScrollBar": .bool(boolValue(
                TerminalScrollBarSettings.showScrollBarKey,
                defaultValue: TerminalScrollBarSettings.defaultShowScrollBar,
                defaults: defaults
            )),
            "notifications.dockBadge": .bool(boolValue(
                NotificationBadgeSettings.dockBadgeEnabledKey,
                defaultValue: NotificationBadgeSettings.defaultDockBadgeEnabled,
                defaults: defaults
            )),
            "notifications.showInMenuBar": .bool(boolValue(
                MenuBarExtraSettings.showInMenuBarKey,
                defaultValue: MenuBarExtraSettings.defaultShowInMenuBar,
                defaults: defaults
            )),
            "notifications.unreadPaneRing": .bool(boolValue(
                NotificationPaneRingSettings.enabledKey,
                defaultValue: NotificationPaneRingSettings.defaultEnabled,
                defaults: defaults
            )),
            "notifications.paneFlash": .bool(boolValue(
                NotificationPaneFlashSettings.enabledKey,
                defaultValue: NotificationPaneFlashSettings.defaultEnabled,
                defaults: defaults
            )),
            "notifications.sound": .string(stringValue(
                NotificationSoundSettings.key,
                defaultValue: NotificationSoundSettings.defaultValue,
                defaults: defaults
            )),
            "notifications.customSoundFilePath": .string(stringValue(
                NotificationSoundSettings.customFilePathKey,
                defaultValue: NotificationSoundSettings.defaultCustomFilePath,
                defaults: defaults
            )),
            "notifications.command": .string(stringValue(
                NotificationSoundSettings.customCommandKey,
                defaultValue: NotificationSoundSettings.defaultCustomCommand,
                defaults: defaults
            )),
            "sidebar.hideAllDetails": .bool(boolValue(
                SidebarWorkspaceDetailSettings.hideAllDetailsKey,
                defaultValue: SidebarWorkspaceDetailSettings.defaultHideAllDetails,
                defaults: defaults
            )),
            "sidebar.branchLayout": .string(boolValue(
                SidebarBranchLayoutSettings.key,
                defaultValue: SidebarBranchLayoutSettings.defaultVerticalLayout,
                defaults: defaults
            ) ? "vertical" : "inline"),
            "sidebar.showNotificationMessage": .bool(boolValue(
                SidebarWorkspaceDetailSettings.showNotificationMessageKey,
                defaultValue: SidebarWorkspaceDetailSettings.defaultShowNotificationMessage,
                defaults: defaults
            )),
            "sidebar.showBranchDirectory": .bool(boolValue("sidebarShowBranchDirectory", defaultValue: true, defaults: defaults)),
            "sidebar.showPullRequests": .bool(boolValue("sidebarShowPullRequest", defaultValue: true, defaults: defaults)),
            "sidebar.makePullRequestsClickable": .bool(boolValue(
                SidebarPullRequestClickabilitySettings.key,
                defaultValue: SidebarPullRequestClickabilitySettings.defaultClickable,
                defaults: defaults
            )),
            "sidebar.openPullRequestLinksInCmuxBrowser": .bool(boolValue(
                BrowserLinkOpenSettings.openSidebarPullRequestLinksInCmuxBrowserKey,
                defaultValue: BrowserLinkOpenSettings.defaultOpenSidebarPullRequestLinksInCmuxBrowser,
                defaults: defaults
            )),
            "sidebar.openPortLinksInCmuxBrowser": .bool(boolValue(
                BrowserLinkOpenSettings.openSidebarPortLinksInCmuxBrowserKey,
                defaultValue: BrowserLinkOpenSettings.defaultOpenSidebarPortLinksInCmuxBrowser,
                defaults: defaults
            )),
            "sidebar.showSSH": .bool(boolValue("sidebarShowSSH", defaultValue: true, defaults: defaults)),
            "sidebar.showPorts": .bool(boolValue("sidebarShowPorts", defaultValue: true, defaults: defaults)),
            "sidebar.showLog": .bool(boolValue("sidebarShowLog", defaultValue: true, defaults: defaults)),
            "sidebar.showProgress": .bool(boolValue("sidebarShowProgress", defaultValue: true, defaults: defaults)),
            "sidebar.showCustomMetadata": .bool(boolValue("sidebarShowStatusPills", defaultValue: true, defaults: defaults)),
            "workspaceColors.indicatorStyle": .string(stringValue(
                SidebarActiveTabIndicatorSettings.styleKey,
                defaultValue: SidebarActiveTabIndicatorSettings.defaultStyle.rawValue,
                defaults: defaults
            )),
            "workspaceColors.selectionColor": .nullableString(defaults.string(forKey: "sidebarSelectionColorHex")),
            "workspaceColors.notificationBadgeColor": .nullableString(defaults.string(forKey: "sidebarNotificationBadgeColorHex")),
            "workspaceColors.colors": .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)),
            "sidebarAppearance.matchTerminalBackground": .bool(boolValue(
                "sidebarMatchTerminalBackground",
                defaultValue: false,
                defaults: defaults
            )),
            "sidebarAppearance.tintColor": .string(stringValue(
                "sidebarTintHex",
                defaultValue: SidebarTintDefaults.hex,
                defaults: defaults
            )),
            "sidebarAppearance.lightModeTintColor": .nullableString(defaults.string(forKey: "sidebarTintHexLight")),
            "sidebarAppearance.darkModeTintColor": .nullableString(defaults.string(forKey: "sidebarTintHexDark")),
            "sidebarAppearance.tintOpacity": .double(doubleValue(
                "sidebarTintOpacity",
                defaultValue: SidebarTintDefaults.opacity,
                defaults: defaults
            )),
            "automation.socketControlMode": .string(stringValue(
                SocketControlSettings.appStorageKey,
                defaultValue: SocketControlSettings.defaultMode.rawValue,
                defaults: defaults
            )),
            "automation.claudeCodeIntegration": .bool(boolValue(
                ClaudeCodeIntegrationSettings.hooksEnabledKey,
                defaultValue: ClaudeCodeIntegrationSettings.defaultHooksEnabled,
                defaults: defaults
            )),
            "automation.claudeBinaryPath": .string(stringValue(
                ClaudeCodeIntegrationSettings.customClaudePathKey,
                defaultValue: "",
                defaults: defaults
            )),
            "automation.cursorIntegration": .bool(boolValue(
                CursorIntegrationSettings.hooksEnabledKey,
                defaultValue: CursorIntegrationSettings.defaultHooksEnabled,
                defaults: defaults
            )),
            "automation.geminiIntegration": .bool(boolValue(
                GeminiIntegrationSettings.hooksEnabledKey,
                defaultValue: GeminiIntegrationSettings.defaultHooksEnabled,
                defaults: defaults
            )),
            "automation.portBase": .int(intValue("cmuxPortBase", defaultValue: 9100, defaults: defaults)),
            "automation.portRange": .int(intValue("cmuxPortRange", defaultValue: 10, defaults: defaults)),
            "browser.defaultSearchEngine": .string(stringValue(
                BrowserSearchSettings.searchEngineKey,
                defaultValue: BrowserSearchSettings.defaultSearchEngine.rawValue,
                defaults: defaults
            )),
            "browser.showSearchSuggestions": .bool(boolValue(
                BrowserSearchSettings.searchSuggestionsEnabledKey,
                defaultValue: BrowserSearchSettings.defaultSearchSuggestionsEnabled,
                defaults: defaults
            )),
            "browser.theme": .string(stringValue(
                BrowserThemeSettings.modeKey,
                defaultValue: BrowserThemeSettings.defaultMode.rawValue,
                defaults: defaults
            )),
            "browser.openTerminalLinksInCmuxBrowser": .bool(boolValue(
                BrowserLinkOpenSettings.openTerminalLinksInCmuxBrowserKey,
                defaultValue: BrowserLinkOpenSettings.defaultOpenTerminalLinksInCmuxBrowser,
                defaults: defaults
            )),
            "browser.interceptTerminalOpenCommandInCmuxBrowser": .bool(boolValue(
                BrowserLinkOpenSettings.interceptTerminalOpenCommandInCmuxBrowserKey,
                defaultValue: BrowserLinkOpenSettings.initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: defaults),
                defaults: defaults
            )),
            "browser.hostsToOpenInEmbeddedBrowser": .stringArray(stringListValue(
                BrowserLinkOpenSettings.browserHostWhitelistKey,
                defaultValue: BrowserLinkOpenSettings.defaultBrowserHostWhitelist,
                defaults: defaults
            )),
            "browser.urlsToAlwaysOpenExternally": .stringArray(stringListValue(
                BrowserLinkOpenSettings.browserExternalOpenPatternsKey,
                defaultValue: BrowserLinkOpenSettings.defaultBrowserExternalOpenPatterns,
                defaults: defaults
            )),
            "browser.insecureHttpHostsAllowedInEmbeddedBrowser": .stringArray(stringListValue(
                BrowserInsecureHTTPSettings.allowlistKey,
                defaultValue: BrowserInsecureHTTPSettings.defaultAllowlistText,
                defaults: defaults
            )),
            "browser.showImportHintOnBlankTabs": .bool(boolValue(
                BrowserImportHintSettings.showOnBlankTabsKey,
                defaultValue: BrowserImportHintSettings.defaultShowOnBlankTabs,
                defaults: defaults
            )),
            "browser.reactGrabVersion": .string(stringValue(
                ReactGrabSettings.versionKey,
                defaultValue: ReactGrabSettings.defaultVersion,
                defaults: defaults
            )),
        ]

        values["shortcuts.showModifierHoldHints"] = .bool(
            boolValue(
                ShortcutHintDebugSettings.showHintsOnCommandHoldKey,
                defaultValue: ShortcutHintDebugSettings.defaultShowHintsOnCommandHold,
                defaults: defaults
            ) &&
            boolValue(
                ShortcutHintDebugSettings.showHintsOnControlHoldKey,
                defaultValue: ShortcutHintDebugSettings.defaultShowHintsOnControlHold,
                defaults: defaults
            )
        )
        return values
    }

    static func persistSettingsJSONValues(
        _ values: [String: ManagedSettingsValue],
        primaryPath: String,
        fileManager: FileManager,
        bootstrapPrimaryTemplate: () -> Void
    ) throws {
        bootstrapPrimaryTemplate()
        let fileURL = URL(fileURLWithPath: primaryPath, isDirectory: false)
        var root = try loadWritableSettingsRoot(from: fileURL, fileManager: fileManager)
        if root["$schema"] == nil {
            root["$schema"] = CmuxSettingsFileStore.schemaURLString
        }
        if root["schemaVersion"] == nil {
            root["schemaVersion"] = CmuxSettingsFileStore.currentSchemaVersion
        }

        for (path, value) in values.sorted(by: { $0.key < $1.key }) {
            setSettingsJSONValue(value.jsonObject, at: path, in: &root)
        }

        var options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys]
        options.insert(.withoutEscapingSlashes)
        let data = try JSONSerialization.data(withJSONObject: root, options: options)
        var output = data
        output.append(0x0A)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try output.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private static func boolValue(_ key: String, defaultValue: Bool, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    private static func intValue(_ key: String, defaultValue: Int, defaults: UserDefaults) -> Int {
        defaults.object(forKey: key) as? Int ?? defaultValue
    }

    private static func doubleValue(_ key: String, defaultValue: Double, defaults: UserDefaults) -> Double {
        defaults.object(forKey: key) as? Double ?? defaultValue
    }

    private static func stringValue(_ key: String, defaultValue: String, defaults: UserDefaults) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private static func stringListValue(_ key: String, defaultValue: String, defaults: UserDefaults) -> [String] {
        stringValue(key, defaultValue: defaultValue, defaults: defaults)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func loadWritableSettingsRoot(from fileURL: URL, fileManager: FileManager) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [:] }
        guard let data = fileManager.contents(atPath: fileURL.path), !data.isEmpty else { return [:] }
        let sanitized = try JSONCParser.preprocess(data: data)
        let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
        guard let root = object as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return root
    }

    private static func setSettingsJSONValue(_ value: Any, at path: String, in root: inout [String: Any]) {
        let components = path.split(separator: ".").map(String.init)
        guard !components.isEmpty else { return }
        setSettingsJSONValue(value, path: components[...], in: &root)
    }

    private static func setSettingsJSONValue(
        _ value: Any,
        path components: ArraySlice<String>,
        in object: inout [String: Any]
    ) {
        guard let key = components.first else { return }
        if components.count == 1 {
            object[key] = value
            return
        }

        var child = object[key] as? [String: Any] ?? [:]
        setSettingsJSONValue(value, path: components.dropFirst(), in: &child)
        object[key] = child
    }
}

enum ManagedSettingsValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case nullableString(String?)
    case stringArray([String])
    case stringDictionary([String: String])

    var jsonObject: Any {
        switch self {
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .nullableString(let value):
            return value ?? NSNull()
        case .stringArray(let value):
            return value
        case .stringDictionary(let value):
            return value
        }
    }
}

enum BackupValue: Codable, Equatable {
    case absent
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case stringArray([String])
    case stringDictionary([String: String])

    private enum Kind: String, Codable {
        case absent
        case bool
        case int
        case double
        case string
        case stringArray
        case stringDictionary
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case boolValue
        case intValue
        case doubleValue
        case stringValue
        case stringArrayValue
        case stringDictionaryValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .absent:
            self = .absent
        case .bool:
            self = .bool(try container.decode(Bool.self, forKey: .boolValue))
        case .int:
            self = .int(try container.decode(Int.self, forKey: .intValue))
        case .double:
            self = .double(try container.decode(Double.self, forKey: .doubleValue))
        case .string:
            self = .string(try container.decode(String.self, forKey: .stringValue))
        case .stringArray:
            self = .stringArray(try container.decode([String].self, forKey: .stringArrayValue))
        case .stringDictionary:
            self = .stringDictionary(try container.decode([String: String].self, forKey: .stringDictionaryValue))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absent:
            try container.encode(Kind.absent, forKey: .kind)
        case .bool(let value):
            try container.encode(Kind.bool, forKey: .kind)
            try container.encode(value, forKey: .boolValue)
        case .int(let value):
            try container.encode(Kind.int, forKey: .kind)
            try container.encode(value, forKey: .intValue)
        case .double(let value):
            try container.encode(Kind.double, forKey: .kind)
            try container.encode(value, forKey: .doubleValue)
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .stringArray(let value):
            try container.encode(Kind.stringArray, forKey: .kind)
            try container.encode(value, forKey: .stringArrayValue)
        case .stringDictionary(let value):
            try container.encode(Kind.stringDictionary, forKey: .kind)
            try container.encode(value, forKey: .stringDictionaryValue)
        }
    }
}
