import Foundation

enum CmuxSettingsRegistry {
    struct SettingDefinition {
        let key: String
        let kind: ValueKind
        let defaultValue: Any
        let isSensitive: Bool

        init(key: String, kind: ValueKind, defaultValue: Any, isSensitive: Bool = false) {
            self.key = key
            self.kind = kind
            self.defaultValue = defaultValue
            self.isSensitive = isSensitive
        }
    }

    enum ValueKind {
        case bool
        case int(min: Int?)
        case double(min: Double?, max: Double?)
        case string(allowEmpty: Bool)
        case enumValue([String], aliases: [String: String] = [:])
        case hexColor
        case nullableHexColor
        case stringList
        case stringDictionary
        case hexColorDictionary
    }

    struct ShortcutActionDefinition {
        let action: String
        let label: String
        let defaultValue: String
        let usesNumberedDigitMatching: Bool
        let aliases: [String]
        let context: ShortcutContext

        init(
            action: String,
            label: String,
            defaultValue: String,
            usesNumberedDigitMatching: Bool,
            aliases: [String],
            context: ShortcutContext = .application
        ) {
            self.action = action
            self.label = label
            self.defaultValue = defaultValue
            self.usesNumberedDigitMatching = usesNumberedDigitMatching
            self.aliases = aliases
            self.context = context
        }
    }

    enum ShortcutContext: String {
        case application
        case nonBrowserPanel
        case browserPanel
        case rightSidebarFocus

        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application {
                return true
            }
            return self == other
        }
    }

    struct ValidationError: Error, CustomStringConvertible {
        let message: String

        var description: String { message }
    }

    static let languageValues = [
        "system", "en", "ar", "bs", "zh-Hans", "zh-Hant", "da", "de", "es", "fr",
        "it", "ja", "ko", "nb", "pl", "pt-BR", "ru", "th", "tr",
    ]

    static let notificationSoundValues = [
        "default", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
        "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        "custom_file", "none",
    ]

    static let defaultInsecureHTTPHosts = [
        "localhost",
        "*.localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]

    static let defaultWorkspaceColors: [String: String] = [
        "Red": "#C0392B",
        "Crimson": "#922B21",
        "Orange": "#A04000",
        "Amber": "#7D6608",
        "Olive": "#4A5C18",
        "Green": "#196F3D",
        "Teal": "#006B6B",
        "Aqua": "#0E6B8C",
        "Blue": "#1565C0",
        "Navy": "#1A5276",
        "Indigo": "#283593",
        "Purple": "#6A1B9A",
        "Magenta": "#AD1457",
        "Rose": "#880E4F",
        "Brown": "#7B3F00",
        "Charcoal": "#3E4B5E",
    ]

    static let settings: [SettingDefinition] = [
        SettingDefinition(key: "app.language", kind: .enumValue(languageValues), defaultValue: "system"),
        SettingDefinition(key: "app.appearance", kind: .enumValue(["system", "light", "dark"], aliases: ["auto": "system"]), defaultValue: "system"),
        SettingDefinition(key: "app.appIcon", kind: .enumValue(["automatic", "light", "dark"]), defaultValue: "automatic"),
        SettingDefinition(key: "app.menuBarOnly", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.newWorkspacePlacement", kind: .enumValue(["top", "afterCurrent", "end"]), defaultValue: "afterCurrent"),
        SettingDefinition(key: "app.minimalMode", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.keepWorkspaceOpenWhenClosingLastSurface", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.focusPaneOnFirstClick", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.fileDropDefaultBehavior", kind: .enumValue(["text", "preview"]), defaultValue: "text"),
        SettingDefinition(key: "app.preferredEditor", kind: .string(allowEmpty: true), defaultValue: ""),
        SettingDefinition(key: "app.openMarkdownInCmuxViewer", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.iMessageMode", kind: .bool, defaultValue: false),
        SettingDefinition(key: "app.reorderOnNotification", kind: .bool, defaultValue: true),
        SettingDefinition(key: "app.sendAnonymousTelemetry", kind: .bool, defaultValue: true),
        SettingDefinition(key: "app.warnBeforeQuit", kind: .bool, defaultValue: true),
        SettingDefinition(key: "app.renameSelectsExistingName", kind: .bool, defaultValue: true),
        SettingDefinition(key: "app.commandPaletteSearchesAllSurfaces", kind: .bool, defaultValue: false),
        SettingDefinition(key: "terminal.showScrollBar", kind: .bool, defaultValue: true),
        SettingDefinition(key: "terminal.autoResumeAgentSessions", kind: .bool, defaultValue: true),
        SettingDefinition(key: "notifications.dockBadge", kind: .bool, defaultValue: true),
        SettingDefinition(key: "notifications.showInMenuBar", kind: .bool, defaultValue: true),
        SettingDefinition(key: "notifications.unreadPaneRing", kind: .bool, defaultValue: true),
        SettingDefinition(key: "notifications.paneFlash", kind: .bool, defaultValue: true),
        SettingDefinition(key: "notifications.sound", kind: .enumValue(notificationSoundValues), defaultValue: "default"),
        SettingDefinition(key: "notifications.customSoundFilePath", kind: .string(allowEmpty: true), defaultValue: ""),
        SettingDefinition(key: "notifications.command", kind: .string(allowEmpty: true), defaultValue: ""),
        SettingDefinition(key: "sidebar.hideAllDetails", kind: .bool, defaultValue: false),
        SettingDefinition(key: "sidebar.branchLayout", kind: .enumValue(["vertical", "inline"]), defaultValue: "vertical"),
        SettingDefinition(key: "sidebar.showNotificationMessage", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showBranchDirectory", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showPullRequests", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.makePullRequestsClickable", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.openPullRequestLinksInCmuxBrowser", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.openPortLinksInCmuxBrowser", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showSSH", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showPorts", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showLog", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showProgress", kind: .bool, defaultValue: true),
        SettingDefinition(key: "sidebar.showCustomMetadata", kind: .bool, defaultValue: true),
        SettingDefinition(key: "workspaceColors.indicatorStyle", kind: .enumValue(["leftRail", "solidFill"], aliases: [
            "rail": "leftRail",
            "border": "solidFill",
            "wash": "solidFill",
            "lift": "solidFill",
            "typography": "solidFill",
            "washRail": "solidFill",
            "blueWashColorRail": "solidFill",
        ]), defaultValue: "leftRail"),
        SettingDefinition(key: "workspaceColors.selectionColor", kind: .nullableHexColor, defaultValue: NSNull()),
        SettingDefinition(key: "workspaceColors.notificationBadgeColor", kind: .nullableHexColor, defaultValue: NSNull()),
        SettingDefinition(key: "workspaceColors.colors", kind: .hexColorDictionary, defaultValue: defaultWorkspaceColors),
        SettingDefinition(key: "workspaceColors.paletteOverrides", kind: .hexColorDictionary, defaultValue: [String: String]()),
        SettingDefinition(key: "workspaceColors.customColors", kind: .stringList, defaultValue: [String]()),
        SettingDefinition(key: "sidebarAppearance.matchTerminalBackground", kind: .bool, defaultValue: false),
        SettingDefinition(key: "sidebarAppearance.tintColor", kind: .hexColor, defaultValue: "#000000"),
        SettingDefinition(key: "sidebarAppearance.lightModeTintColor", kind: .nullableHexColor, defaultValue: NSNull()),
        SettingDefinition(key: "sidebarAppearance.darkModeTintColor", kind: .nullableHexColor, defaultValue: NSNull()),
        SettingDefinition(key: "sidebarAppearance.tintOpacity", kind: .double(min: 0, max: 1), defaultValue: 0.18),
        SettingDefinition(key: "automation.socketControlMode", kind: .enumValue(["off", "cmuxOnly", "automation", "password", "allowAll"], aliases: [
            "cmuxonly": "cmuxOnly",
            "allowall": "allowAll",
            "openaccess": "allowAll",
            "fullopenaccess": "allowAll",
            "notifications": "automation",
            "full": "allowAll",
        ]), defaultValue: "cmuxOnly"),
        SettingDefinition(key: "automation.socketPassword", kind: .string(allowEmpty: true), defaultValue: "", isSensitive: true),
        SettingDefinition(key: "automation.claudeCodeIntegration", kind: .bool, defaultValue: true),
        SettingDefinition(key: "automation.claudeBinaryPath", kind: .string(allowEmpty: true), defaultValue: ""),
        SettingDefinition(key: "automation.cursorIntegration", kind: .bool, defaultValue: true),
        SettingDefinition(key: "automation.geminiIntegration", kind: .bool, defaultValue: true),
        SettingDefinition(key: "automation.portBase", kind: .int(min: 1), defaultValue: 9100),
        SettingDefinition(key: "automation.portRange", kind: .int(min: 1), defaultValue: 10),
        SettingDefinition(key: "browser.enabled", kind: .bool, defaultValue: true),
        SettingDefinition(key: "browser.defaultSearchEngine", kind: .enumValue(["google", "duckduckgo", "bing", "kagi", "startpage"]), defaultValue: "google"),
        SettingDefinition(key: "browser.showSearchSuggestions", kind: .bool, defaultValue: true),
        SettingDefinition(key: "browser.theme", kind: .enumValue(["system", "light", "dark"]), defaultValue: "system"),
        SettingDefinition(key: "browser.openTerminalLinksInCmuxBrowser", kind: .bool, defaultValue: true),
        SettingDefinition(key: "browser.interceptTerminalOpenCommandInCmuxBrowser", kind: .bool, defaultValue: true),
        SettingDefinition(key: "browser.hostsToOpenInEmbeddedBrowser", kind: .stringList, defaultValue: [String]()),
        SettingDefinition(key: "browser.urlsToAlwaysOpenExternally", kind: .stringList, defaultValue: [String]()),
        SettingDefinition(key: "browser.insecureHttpHostsAllowedInEmbeddedBrowser", kind: .stringList, defaultValue: defaultInsecureHTTPHosts),
        SettingDefinition(key: "browser.showImportHintOnBlankTabs", kind: .bool, defaultValue: true),
        SettingDefinition(key: "browser.reactGrabVersion", kind: .enumValue(["0.1.29"]), defaultValue: "0.1.29"),
        SettingDefinition(key: "globalHotkey.enabled", kind: .bool, defaultValue: false),
        SettingDefinition(key: "rightSidebar.beta.feed.enabled", kind: .bool, defaultValue: false),
        SettingDefinition(key: "rightSidebar.beta.dock.enabled", kind: .bool, defaultValue: false),
    ]

    static let definitionsByKey = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })
    static let sortedKeys = settings.map(\.key).sorted()
    static let supportedSettingsJSONPaths = Set(sortedKeys).union(["shortcuts.bindings"])

    static let shortcutActions: [ShortcutActionDefinition] = [
        ShortcutActionDefinition(action: "openSettings", label: "Settings", defaultValue: "cmd+,", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "reloadConfiguration", label: "Reload Configuration", defaultValue: "cmd+shift+,", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "showHideAllWindows", label: "Show/Hide All Windows", defaultValue: "cmd+option+ctrl+.", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "newWindow", label: "New Window", defaultValue: "cmd+shift+n", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "closeWindow", label: "Close Window", defaultValue: "cmd+ctrl+w", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleFullScreen", label: "Toggle Full Screen", defaultValue: "cmd+ctrl+f", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "quit", label: "Quit cmux", defaultValue: "cmd+q", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleSidebar", label: "Toggle Left Sidebar", defaultValue: "cmd+b", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "newTab", label: "New Workspace", defaultValue: "cmd+n", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "openFolder", label: "Open Folder", defaultValue: "cmd+o", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "reopenPreviousSession", label: "Reopen Previous Session", defaultValue: "cmd+shift+o", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "goToWorkspace", label: "Go to Workspace", defaultValue: "cmd+p", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "commandPalette", label: "Command Palette", defaultValue: "cmd+shift+p", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "commandPaletteNext", label: "Command Palette: Next", defaultValue: "ctrl+n", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "commandPalettePrevious", label: "Command Palette: Previous", defaultValue: "ctrl+p", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "sendFeedback", label: "Send Feedback", defaultValue: "cmd+option+f", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "showNotifications", label: "Show Notifications", defaultValue: "cmd+i", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "jumpToUnread", label: "Jump to Latest Unread", defaultValue: "cmd+shift+u", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusRightSidebar", label: "Toggle Right Sidebar Focus", defaultValue: "cmd+shift+e", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleFileExplorer", label: "Open file explorer", defaultValue: "cmd+option+b", usesNumberedDigitMatching: false, aliases: ["toggleRightSidebar"]),
        ShortcutActionDefinition(action: "findInDirectory", label: "Find in Directory", defaultValue: "cmd+shift+f", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "triggerFlash", label: "Flash Focused Panel", defaultValue: "cmd+shift+h", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "nextSurface", label: "Next Surface", defaultValue: "cmd+shift+]", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "prevSurface", label: "Previous Surface", defaultValue: "cmd+shift+[", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "selectSurfaceByNumber", label: "Select Surface 1-9", defaultValue: "ctrl+1", usesNumberedDigitMatching: true, aliases: []),
        ShortcutActionDefinition(action: "nextSidebarTab", label: "Next Workspace", defaultValue: "cmd+ctrl+]", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "prevSidebarTab", label: "Previous Workspace", defaultValue: "cmd+ctrl+[", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "selectWorkspaceByNumber", label: "Select Workspace 1-9", defaultValue: "cmd+1", usesNumberedDigitMatching: true, aliases: []),
        ShortcutActionDefinition(action: "renameTab", label: "Rename Tab", defaultValue: "cmd+r", usesNumberedDigitMatching: false, aliases: [], context: .nonBrowserPanel),
        ShortcutActionDefinition(action: "renameWorkspace", label: "Rename Workspace", defaultValue: "cmd+shift+r", usesNumberedDigitMatching: false, aliases: [], context: .nonBrowserPanel),
        ShortcutActionDefinition(action: "editWorkspaceDescription", label: "Edit Workspace Description", defaultValue: "cmd+option+e", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "closeTab", label: "Close Tab", defaultValue: "cmd+w", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "closeOtherTabsInPane", label: "Close Other Tabs in Pane", defaultValue: "cmd+option+t", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "closeWorkspace", label: "Close Workspace", defaultValue: "cmd+shift+w", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "reopenClosedBrowserPanel", label: "Reopen Closed Browser Panel", defaultValue: "cmd+shift+t", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "newSurface", label: "New Surface", defaultValue: "cmd+t", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleTerminalCopyMode", label: "Toggle Terminal Copy Mode", defaultValue: "cmd+shift+m", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusLeft", label: "Focus Pane Left", defaultValue: "cmd+option+left", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusRight", label: "Focus Pane Right", defaultValue: "cmd+option+right", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusUp", label: "Focus Pane Up", defaultValue: "cmd+option+up", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusDown", label: "Focus Pane Down", defaultValue: "cmd+option+down", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "splitRight", label: "Split Right", defaultValue: "cmd+d", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "splitDown", label: "Split Down", defaultValue: "cmd+shift+d", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleSplitZoom", label: "Toggle Pane Zoom", defaultValue: "cmd+shift+return", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "equalizeSplits", label: "Equalize Splits", defaultValue: "cmd+ctrl+=", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "splitBrowserRight", label: "Split Browser Right", defaultValue: "cmd+option+d", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "splitBrowserDown", label: "Split Browser Down", defaultValue: "cmd+shift+option+d", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "saveFilePreview", label: "Save File Preview", defaultValue: "cmd+s", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "openBrowser", label: "Open Browser", defaultValue: "cmd+shift+l", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "focusBrowserAddressBar", label: "Focus Address Bar", defaultValue: "cmd+l", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "browserBack", label: "Browser Back", defaultValue: "cmd+[", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "browserForward", label: "Browser Forward", defaultValue: "cmd+]", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "browserReload", label: "Browser Reload", defaultValue: "cmd+r", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "browserZoomIn", label: "Browser Zoom In", defaultValue: "cmd+=", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "browserZoomOut", label: "Browser Zoom Out", defaultValue: "cmd+-", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "browserZoomReset", label: "Browser Actual Size", defaultValue: "cmd+0", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "find", label: "Find", defaultValue: "cmd+f", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "findNext", label: "Find Next", defaultValue: "cmd+g", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "findPrevious", label: "Find Previous", defaultValue: "cmd+option+g", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "hideFind", label: "Hide Find Bar", defaultValue: "cmd+shift+option+f", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "useSelectionForFind", label: "Use Selection for Find", defaultValue: "cmd+e", usesNumberedDigitMatching: false, aliases: []),
        ShortcutActionDefinition(action: "toggleBrowserDeveloperTools", label: "Toggle Browser Developer Tools", defaultValue: "cmd+option+i", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "showBrowserJavaScriptConsole", label: "Show Browser JavaScript Console", defaultValue: "cmd+option+c", usesNumberedDigitMatching: false, aliases: [], context: .browserPanel),
        ShortcutActionDefinition(action: "toggleReactGrab", label: "Toggle React Grab", defaultValue: "cmd+shift+g", usesNumberedDigitMatching: false, aliases: []),
    ]

    static let shortcutActionsByName: [String: ShortcutActionDefinition] = {
        var result: [String: ShortcutActionDefinition] = [:]
        for definition in shortcutActions {
            result[definition.action] = definition
            result[definition.action.lowercased()] = definition
            for alias in definition.aliases {
                result[alias] = definition
                result[alias.lowercased()] = definition
            }
        }
        return result
    }()

    static let sortedShortcutActions = shortcutActions.map(\.action).sorted()

    static func definition(for key: String) throws -> SettingDefinition {
        guard let definition = definitionsByKey[key] else {
            throw ValidationError(message: "Unknown setting key '\(key)'")
        }
        return definition
    }

    static func shortcutAction(for action: String) throws -> ShortcutActionDefinition {
        guard let definition = shortcutActionsByName[action] ?? shortcutActionsByName[action.lowercased()] else {
            throw ValidationError(message: "Unknown shortcut action '\(action)'")
        }
        return definition
    }

    static func normalizeCommandLineValue(_ raw: String, for definition: SettingDefinition) throws -> Any {
        if case .string = definition.kind {
            return try normalizeJSONValue(raw, for: definition)
        }

        if let jsonValue = parseJSONLiteral(raw) {
            return try normalizeJSONValue(jsonValue, for: definition)
        }

        switch definition.kind {
        case .bool:
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "on", "1":
                return true
            case "false", "no", "off", "0":
                return false
            default:
                throw ValidationError(message: "\(definition.key) expects true or false")
            }
        case .int:
            guard let value = Int(raw) else {
                throw ValidationError(message: "\(definition.key) expects an integer")
            }
            return try normalizeJSONValue(value, for: definition)
        case .double:
            guard let value = Double(raw) else {
                throw ValidationError(message: "\(definition.key) expects a number")
            }
            return try normalizeJSONValue(value, for: definition)
        case .string:
            return try normalizeJSONValue(raw, for: definition)
        case .enumValue:
            return try normalizeJSONValue(raw, for: definition)
        case .hexColor:
            return try normalizeJSONValue(raw, for: definition)
        case .nullableHexColor:
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["null", "none", "default", "system"].contains(normalized) {
                return NSNull()
            }
            return try normalizeJSONValue(raw, for: definition)
        case .stringList:
            let values = raw
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return try normalizeJSONValue(values, for: definition)
        case .stringDictionary, .hexColorDictionary:
            throw ValidationError(message: "\(definition.key) expects a JSON object value")
        }
    }

    static func normalizeJSONValue(_ value: Any, for definition: SettingDefinition) throws -> Any {
        switch definition.kind {
        case .bool:
            guard let bool = value as? Bool else {
                throw ValidationError(message: "\(definition.key) expects a boolean")
            }
            return bool
        case let .int(min):
            guard let int = numericInt(value), !(value is Bool) else {
                throw ValidationError(message: "\(definition.key) expects an integer")
            }
            if let min, int < min {
                throw ValidationError(message: "\(definition.key) must be >= \(min)")
            }
            return int
        case let .double(min, max):
            guard let double = numericDouble(value), !(value is Bool) else {
                throw ValidationError(message: "\(definition.key) expects a number")
            }
            if let min, double < min {
                throw ValidationError(message: "\(definition.key) must be >= \(min)")
            }
            if let max, double > max {
                throw ValidationError(message: "\(definition.key) must be <= \(max)")
            }
            return double
        case let .string(allowEmpty):
            guard let string = value as? String else {
                throw ValidationError(message: "\(definition.key) expects a string")
            }
            if !allowEmpty && string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError(message: "\(definition.key) cannot be empty")
            }
            return string
        case let .enumValue(values, aliases):
            guard let raw = value as? String else {
                throw ValidationError(message: "\(definition.key) expects one of: \(values.joined(separator: ", "))")
            }
            if values.contains(raw) {
                return aliases[raw] ?? raw
            }
            let normalized = raw
                .normalizedEnumToken
            if let alias = aliases[raw] ?? aliases[normalized] {
                return alias
            }
            if let alias = aliases.first(where: { $0.key.normalizedEnumToken == normalized })?.value {
                return alias
            }
            if let canonical = values.first(where: { $0.normalizedEnumToken == normalized }) {
                return aliases[canonical] ?? canonical
            }
            throw ValidationError(message: "\(definition.key) expects one of: \(values.joined(separator: ", "))")
        case .hexColor:
            guard let raw = value as? String, let normalized = normalizeHexColor(raw) else {
                throw ValidationError(message: "\(definition.key) expects a #RRGGBB hex color")
            }
            return normalized
        case .nullableHexColor:
            if value is NSNull {
                return NSNull()
            }
            guard let raw = value as? String, let normalized = normalizeHexColor(raw) else {
                throw ValidationError(message: "\(definition.key) expects a #RRGGBB hex color or null")
            }
            return normalized
        case .stringList:
            guard let rawValues = value as? [Any] else {
                throw ValidationError(message: "\(definition.key) expects an array of strings")
            }
            return try rawValues.map { value in
                guard let string = value as? String else {
                    throw ValidationError(message: "\(definition.key) expects an array of strings")
                }
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        case .stringDictionary:
            guard let raw = value as? [String: Any] else {
                throw ValidationError(message: "\(definition.key) expects an object")
            }
            var normalized: [String: String] = [:]
            for (key, value) in raw {
                guard let string = value as? String else {
                    throw ValidationError(message: "\(definition.key).\(key) expects a string")
                }
                normalized[key] = string
            }
            return normalized
        case .hexColorDictionary:
            guard let raw = value as? [String: Any] else {
                throw ValidationError(message: "\(definition.key) expects an object")
            }
            var normalized: [String: String] = [:]
            for (key, value) in raw {
                guard let string = value as? String, let color = normalizeHexColor(string) else {
                    throw ValidationError(message: "\(definition.key).\(key) expects a #RRGGBB hex color")
                }
                normalized[key] = color
            }
            return normalized
        }
    }

    static func parseJSONLiteral(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first,
              first == "{" || first == "[" || first == "\"" ||
              first == "t" || first == "f" || first == "n" ||
              first == "-" || first.isNumber else {
            return nil
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return value
    }

    static func normalizeHexColor(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6,
              hex.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            return nil
        }
        return "#\(hex.uppercased())"
    }

    private static func numericInt(_ value: Any) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.rounded() == double else { return nil }
            return number.intValue
        }
        return nil
    }

    private static func numericDouble(_ value: Any) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }
}

private extension String {
    var normalizedEnumToken: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
    }
}
