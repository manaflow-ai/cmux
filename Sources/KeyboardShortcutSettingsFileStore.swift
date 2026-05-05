import Combine
import Foundation

@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0

    private var settingsCancellable: AnyCancellable?
    private var recorderCancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        settingsCancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
        recorderCancellable = notificationCenter.publisher(for: KeyboardShortcutRecorderActivity.didChangeNotification)
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
    }
}

final class CmuxSettingsFileStore {
    static let shared = CmuxSettingsFileStore()

    static let currentSchemaVersion = 1
    static let schemaURLString = "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"
    private static let legacySchemaURLString = "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json"
    // Keep this in sync with the parser below and the web schema/docs. Settings UI rows
    // validate against this set so new persisted settings need an explicit cmux.json review.
    static let supportedSettingsJSONPaths: Set<String> = [
        "app.language",
        "app.appearance",
        "app.appIcon",
        "app.menuBarOnly",
        "app.newWorkspacePlacement",
        "app.minimalMode",
        "app.keepWorkspaceOpenWhenClosingLastSurface",
        "app.focusPaneOnFirstClick",
        "app.preferredEditor",
        "app.openMarkdownInCmuxViewer",
        "app.iMessageMode",
        "app.reorderOnNotification",
        "app.sendAnonymousTelemetry",
        "app.warnBeforeQuit",
        "app.renameSelectsExistingName",
        "app.commandPaletteSearchesAllSurfaces",
        "terminal.showScrollBar",
        "notifications.dockBadge",
        "notifications.showInMenuBar",
        "notifications.unreadPaneRing",
        "notifications.paneFlash",
        "notifications.sound",
        "notifications.customSoundFilePath",
        "notifications.command",
        "sidebar.hideAllDetails",
        "sidebar.branchLayout",
        "sidebar.showNotificationMessage",
        "sidebar.showBranchDirectory",
        "sidebar.showPullRequests",
        "sidebar.makePullRequestsClickable",
        "sidebar.openPullRequestLinksInCmuxBrowser",
        "sidebar.openPortLinksInCmuxBrowser",
        "sidebar.showSSH",
        "sidebar.showPorts",
        "sidebar.showLog",
        "sidebar.showProgress",
        "sidebar.showCustomMetadata",
        "workspaceColors.indicatorStyle",
        "workspaceColors.selectionColor",
        "workspaceColors.notificationBadgeColor",
        "workspaceColors.colors",
        "workspaceColors.paletteOverrides",
        "workspaceColors.customColors",
        "sidebarAppearance.matchTerminalBackground",
        "sidebarAppearance.tintColor",
        "sidebarAppearance.lightModeTintColor",
        "sidebarAppearance.darkModeTintColor",
        "sidebarAppearance.tintOpacity",
        "automation.socketControlMode",
        "automation.socketPassword",
        "automation.claudeCodeIntegration",
        "automation.claudeBinaryPath",
        "automation.cursorIntegration",
        "automation.geminiIntegration",
        "automation.portBase",
        "automation.portRange",
        "browser.defaultSearchEngine",
        "browser.showSearchSuggestions",
        "browser.theme",
        "browser.openTerminalLinksInCmuxBrowser",
        "browser.interceptTerminalOpenCommandInCmuxBrowser",
        "browser.hostsToOpenInEmbeddedBrowser",
        "browser.urlsToAlwaysOpenExternally",
        "browser.insecureHttpHostsAllowedInEmbeddedBrowser",
        "browser.showImportHintOnBlankTabs",
        "browser.reactGrabVersion",
        "shortcuts.showModifierHoldHints",
        "shortcuts.bindings",
    ]

    private static let releaseBundleIdentifier = "com.cmuxterm.app"
    private static let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
    fileprivate static let socketPasswordBackupIdentifier = "automation.socketPassword"

    static var defaultPrimaryPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/cmux.json")
    }

    static var defaultFallbackPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".config/cmux/settings.json")
    }

    static var defaultApplicationSupportFallbackPath: String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return appSupport
            .appendingPathComponent(releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
    }

    private let primaryPath: String
    private let fallbackPaths: [String]
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let stateLock = NSLock()

    private var primaryWatcher: ShortcutSettingsFileWatcher?
    private var fallbackWatchers: [ShortcutSettingsFileWatcher] = []
    private var defaultsCancellable: AnyCancellable?
    private var socketPasswordObserver: NSObjectProtocol?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var activeManagedUserDefaults: [String: ManagedSettingsValue] = [:]
    private var activeManagedCustomSettings = ManagedCustomSettings()
    private var isApplyingManagedSettings = false
    private(set) var activeSourcePath: String?

    init(
        primaryPath: String = CmuxSettingsFileStore.defaultPrimaryPath,
        fallbackPath: String? = CmuxSettingsFileStore.defaultFallbackPath,
        additionalFallbackPaths: [String] = [CmuxSettingsFileStore.defaultApplicationSupportFallbackPath].compactMap { $0 },
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        startWatching: Bool = true
    ) {
        self.primaryPath = primaryPath
        self.fallbackPaths = ([fallbackPath].compactMap { $0 } + additionalFallbackPaths)
            .filter { $0 != primaryPath }
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter

        bootstrapPrimaryTemplateIfNeeded()
        reload()
        guard startWatching else { return }

        primaryWatcher = ShortcutSettingsFileWatcher(path: primaryPath, fileManager: fileManager) { [weak self] in
            DispatchQueue.main.async {
                self?.reload()
            }
        }
        fallbackWatchers = fallbackPaths.map { fallbackPath in
            ShortcutSettingsFileWatcher(path: fallbackPath, fileManager: fileManager) { [weak self] in
                DispatchQueue.main.async {
                    self?.reload()
                }
            }
        }

        defaultsCancellable = notificationCenter.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak self] _ in
                self?.reapplyManagedSettingsIfNeeded()
            }
        socketPasswordObserver = notificationCenter.addObserver(
            forName: SocketControlPasswordStore.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.reapplyManagedSettingsIfNeeded()
        }
    }

    deinit {
        primaryWatcher?.stop()
        fallbackWatchers.forEach { $0.stop() }
        defaultsCancellable?.cancel()
        if let socketPasswordObserver {
            notificationCenter.removeObserver(socketPasswordObserver)
        }
    }

    func reload() {
        let previousShortcuts = synchronized { shortcutsByAction }
        let previousActiveSourcePath = synchronized { activeSourcePath }
        let resolved = resolveSettings()
        applyManagedSettings(snapshot: resolved)
        synchronized {
            shortcutsByAction = resolved.shortcuts
            activeManagedUserDefaults = resolved.managedUserDefaults
            activeManagedCustomSettings = resolved.managedCustomSettings
            activeSourcePath = resolved.path
        }

        if previousShortcuts != resolved.shortcuts || previousActiveSourcePath != resolved.path {
            KeyboardShortcutSettings.notifySettingsFileDidChange(center: notificationCenter)
        }
    }

    func override(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        synchronized { shortcutsByAction[action] }
    }

    func isManagedByFile(_ action: KeyboardShortcutSettings.Action) -> Bool {
        synchronized { shortcutsByAction[action] != nil }
    }

    func settingsFileURLForEditing() -> URL {
        bootstrapPrimaryTemplateIfNeeded()
        return URL(fileURLWithPath: primaryPath)
    }

    func settingsFileDisplayPath() -> String {
        (primaryPath as NSString).abbreviatingWithTildeInPath
    }

    private func bootstrapPrimaryTemplateIfNeeded() {
        guard !fileManager.fileExists(atPath: primaryPath) else { return }

        let fileURL = URL(fileURLWithPath: primaryPath)
        let directoryURL = fileURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
            let contents = legacySettingsDataForBootstrap() ?? Data(Self.defaultTemplate().utf8)
            try contents.write(to: fileURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("[CmuxSettingsFileStore] failed to bootstrap %@: %@", primaryPath, String(describing: error))
        }
    }

    private func legacySettingsDataForBootstrap() -> Data? {
        for fallbackPath in fallbackPaths {
            guard let data = fileManager.contents(atPath: fallbackPath), !data.isEmpty else {
                continue
            }
            guard case .parsed = loadSettings(at: fallbackPath) else {
                continue
            }
            guard let source = String(data: data, encoding: .utf8) else {
                return data
            }
            let updated = source.replacingOccurrences(of: Self.legacySchemaURLString, with: Self.schemaURLString)
            return Data(updated.utf8)
        }
        return nil
    }

    private func reapplyManagedSettingsIfNeeded() {
        let snapshot: ResolvedSettingsSnapshot? = synchronized {
            guard !isApplyingManagedSettings else { return nil }
            if activeManagedUserDefaults.isEmpty && activeManagedCustomSettings.isEmpty {
                return nil
            }
            return ResolvedSettingsSnapshot(
                path: activeSourcePath,
                shortcuts: shortcutsByAction,
                managedUserDefaults: activeManagedUserDefaults,
                managedCustomSettings: activeManagedCustomSettings
            )
        }
        guard let snapshot else { return }
        applyManagedSettings(snapshot: snapshot, updateBackups: false)
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func resolveSettings() -> ResolvedSettingsSnapshot {
        switch loadSettings(at: primaryPath) {
        case .parsed(var snapshot):
            mergeFallbackSettings(into: &snapshot)
            return snapshot
        case .invalid:
            return ResolvedSettingsSnapshot(path: primaryPath)
        case .missing:
            break
        }

        var fallbackSnapshot = ResolvedSettingsSnapshot(path: nil)
        mergeFallbackSettings(into: &fallbackSnapshot)
        return fallbackSnapshot
    }

    private func mergeFallbackSettings(into snapshot: inout ResolvedSettingsSnapshot) {
        for fallbackPath in fallbackPaths {
            guard case .parsed(let fallbackSnapshot) = loadSettings(at: fallbackPath) else {
                continue
            }
            snapshot.fillMissingSettings(from: fallbackSnapshot)
        }
    }

    private enum LoadResult {
        case missing
        case invalid
        case parsed(ResolvedSettingsSnapshot)
    }

    private func loadSettings(at path: String) -> LoadResult {
        guard fileManager.fileExists(atPath: path) else {
            return .missing
        }
        guard let data = fileManager.contents(atPath: path), !data.isEmpty else {
            return .invalid
        }

        do {
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized, options: [])
            guard let root = object as? [String: Any] else {
                return .invalid
            }
            return .parsed(parseSettingsFile(root: root, sourcePath: path))
        } catch {
            NSLog("[CmuxSettingsFileStore] parse error at %@: %@", path, String(describing: error))
            return .invalid
        }
    }

    private func parseSettingsFile(root: [String: Any], sourcePath: String) -> ResolvedSettingsSnapshot {
        let schemaVersion = jsonInt(root["schemaVersion"]) ?? 1
        if schemaVersion > Self.currentSchemaVersion {
            NSLog(
                "[CmuxSettingsFileStore] %@ uses future schemaVersion %d; parsing known fields only",
                sourcePath,
                schemaVersion
            )
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
        if let value = jsonBool(section["warnBeforeQuit"]) {
            snapshot.managedUserDefaults[QuitWarningSettings.warnBeforeQuitKey] = .bool(value)
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
    }

    private func parseSidebarSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        if let value = jsonBool(section["hideAllDetails"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceDetailSettings.hideAllDetailsKey] = .bool(value)
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
        if let value = jsonBool(section["showNotificationMessage"]) {
            snapshot.managedUserDefaults[SidebarWorkspaceDetailSettings.showNotificationMessageKey] = .bool(value)
        }
        if let value = jsonBool(section["showBranchDirectory"]) { snapshot.managedUserDefaults["sidebarShowBranchDirectory"] = .bool(value) }
        if let value = jsonBool(section["showPullRequests"]) { snapshot.managedUserDefaults["sidebarShowPullRequest"] = .bool(value) }
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
                    NSLog("[CmuxSettingsFileStore] ignoring empty workspace color name in %@", sourcePath)
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    NSLog("[CmuxSettingsFileStore] ignoring invalid workspace color '%@' in %@", name, sourcePath)
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
                    NSLog("[CmuxSettingsFileStore] ignoring unknown workspace color '%@' in %@", name, sourcePath)
                    continue
                }
                guard let hex = jsonString(rawValue),
                      let normalizedHex = WorkspaceTabColorSettings.normalizedHex(hex) else {
                    NSLog("[CmuxSettingsFileStore] ignoring invalid workspace color override '%@' in %@", name, sourcePath)
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
            snapshot.managedUserDefaults["sidebarMatchTerminalBackground"] = .bool(value)
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
        if let value = jsonBool(section["cursorIntegration"]) {
            snapshot.managedUserDefaults[CursorIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let value = jsonBool(section["geminiIntegration"]) {
            snapshot.managedUserDefaults[GeminiIntegrationSettings.hooksEnabledKey] = .bool(value)
        }
        if let value = jsonInt(section["portBase"]) {
            guard value > 0 else {
                logInvalid("automation.portBase", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults["cmuxPortBase"] = .int(value)
        }
        if let value = jsonInt(section["portRange"]) {
            guard value > 0 else {
                logInvalid("automation.portRange", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults["cmuxPortRange"] = .int(value)
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

    private func parseShortcutsSection(
        _ value: Any,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let section = value as? [String: Any] else {
            logInvalid("shortcuts", sourcePath: sourcePath)
            return
        }

        if let value = jsonBool(section["showModifierHoldHints"]) {
            snapshot.managedUserDefaults[ShortcutHintDebugSettings.showHintsOnCommandHoldKey] = .bool(value)
            snapshot.managedUserDefaults[ShortcutHintDebugSettings.showHintsOnControlHoldKey] = .bool(value)
        }

        var bindings = section["bindings"] as? [String: Any] ?? [:]
        for (key, rawValue) in section where key != "bindings" && key != "showModifierHoldHints" {
            bindings[key] = rawValue
        }

        for (rawAction, rawBinding) in bindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: rawAction) else {
                NSLog("[CmuxSettingsFileStore] ignoring unknown shortcut action '%@' in %@", rawAction, sourcePath)
                continue
            }
            guard let shortcut = parseShortcutBindingValue(rawBinding, action: action) else {
                NSLog(
                    "[CmuxSettingsFileStore] ignoring invalid shortcut binding for '%@' in %@",
                    rawAction,
                    sourcePath
                )
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
            if let stroke = jsonString(rawValue) { return StoredShortcut.parseConfig(stroke) }
            if let strokes = jsonStringArray(rawValue) {
                return strokes.isEmpty ? .unbound : StoredShortcut.parseConfig(strokes: strokes)
            }
            return nil
        }()

        guard let shortcut else { return nil }
        return action.normalizedSettingsFileShortcut(shortcut)
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

    private func applyManagedSettings(
        snapshot: ResolvedSettingsSnapshot,
        updateBackups: Bool = true
    ) {
        var backups = loadBackups()
        let currentManagedIdentifiers = Set(backups.keys)
        let nextManagedIdentifiers = Set(snapshot.managedUserDefaults.keys)
            .union(snapshot.managedCustomSettings.managedIdentifiers)

        synchronized {
            isApplyingManagedSettings = true
        }
        defer {
            synchronized {
                isApplyingManagedSettings = false
            }
        }

        if updateBackups {
            for (defaultsKey, value) in snapshot.managedUserDefaults where backups[defaultsKey] == nil {
                backups[defaultsKey] = backupValueForUserDefaultsKey(defaultsKey, managedValue: value)
            }
            if snapshot.managedCustomSettings.socketPassword != nil,
               backups[Self.socketPasswordBackupIdentifier] == nil {
                backups[Self.socketPasswordBackupIdentifier] = currentSocketPasswordBackupValue()
            }
        }

        for identifier in currentManagedIdentifiers.subtracting(nextManagedIdentifiers) {
            guard let backup = backups[identifier] else { continue }
            restoreBackup(backup, for: identifier)
            backups.removeValue(forKey: identifier)
        }

        for (defaultsKey, value) in snapshot.managedUserDefaults {
            applyManagedUserDefaultsValue(value, for: defaultsKey)
        }
        applyManagedCustomSettings(snapshot.managedCustomSettings)

        if updateBackups {
            saveBackups(backups)
        }
    }

    private func applyManagedCustomSettings(_ settings: ManagedCustomSettings) {
        if let socketPassword = settings.socketPassword {
            switch socketPassword {
            case .set(let value):
                let current = (try? SocketControlPasswordStore.loadPassword()) ?? nil
                if current != value {
                    try? SocketControlPasswordStore.savePassword(value)
                }
            case .clear:
                let current = (try? SocketControlPasswordStore.loadPassword()) ?? nil
                if current != nil {
                    try? SocketControlPasswordStore.clearPassword()
                }
            }
        }
    }

    private func restoreBackup(_ backup: BackupValue, for identifier: String) {
        switch identifier {
        case Self.socketPasswordBackupIdentifier:
            switch backup {
            case .string(let value):
                try? SocketControlPasswordStore.savePassword(value)
            case .absent:
                try? SocketControlPasswordStore.clearPassword()
            default:
                break
            }
        default:
            restoreUserDefaultsBackup(backup, for: identifier)
        }
    }

    private func backupValueForUserDefaultsKey(_ defaultsKey: String, managedValue: ManagedSettingsValue) -> BackupValue {
        let defaults = UserDefaults.standard
        switch managedValue {
        case .bool:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .bool(defaults.bool(forKey: defaultsKey))
        case .int:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .int(defaults.integer(forKey: defaultsKey))
        case .double:
            guard defaults.object(forKey: defaultsKey) != nil else { return .absent }
            return .double(defaults.double(forKey: defaultsKey))
        case .string, .nullableString:
            guard let value = defaults.string(forKey: defaultsKey) else { return .absent }
            return .string(value)
        case .stringArray:
            guard let value = defaults.array(forKey: defaultsKey) as? [String] else { return .absent }
            return .stringArray(value)
        case .stringDictionary:
            if defaultsKey == WorkspaceTabColorSettings.paletteKey {
                guard let value = WorkspaceTabColorSettings.backupPaletteMap(defaults: defaults) else {
                    return .absent
                }
                return .stringDictionary(value)
            }
            guard let value = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
                return .absent
            }
            return .stringDictionary(value)
        }
    }

    private func currentSocketPasswordBackupValue() -> BackupValue {
        guard let current = try? SocketControlPasswordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func applyManagedUserDefaultsValue(_ value: ManagedSettingsValue, for defaultsKey: String) {
        let defaults = UserDefaults.standard
        if defaultsKey == WorkspaceTabColorSettings.paletteKey,
           case .stringDictionary(let next) = value {
            let current = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
            if current != next {
                WorkspaceTabColorSettings.persistPaletteMap(next, defaults: defaults)
            }
            return
        }

        var didMutateStoredValue = false
        switch value {
        case .bool(let next):
            let current = defaults.object(forKey: defaultsKey) as? Bool
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .int(let next):
            let current = defaults.object(forKey: defaultsKey) as? Int
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .double(let next):
            let current = defaults.object(forKey: defaultsKey) as? Double
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .string(let next):
            let current = defaults.string(forKey: defaultsKey)
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .nullableString(let next):
            let current = defaults.string(forKey: defaultsKey)
            if current != next {
                if let next {
                    defaults.set(next, forKey: defaultsKey)
                } else {
                    defaults.removeObject(forKey: defaultsKey)
                }
                didMutateStoredValue = true
            }
        case .stringArray(let next):
            let current = defaults.array(forKey: defaultsKey) as? [String]
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringDictionary(let next):
            let current = defaults.dictionary(forKey: defaultsKey) as? [String: String]
            if current != next {
                defaults.set(next, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        }

        if defaultsKey == TerminalScrollBarSettings.showScrollBarKey, didMutateStoredValue {
            TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
        }

        switch defaultsKey {
        case LanguageSettings.languageKey:
            let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
            LanguageSettings.apply(language)
        case AppearanceSettings.appearanceModeKey:
            AppearanceSettings.applyStoredMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey), source: "cmuxConfig.applyManagedDefault")
        case AppIconSettings.modeKey:
            AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
        default:
            break
        }
    }

    private func restoreUserDefaultsBackup(_ backup: BackupValue, for defaultsKey: String) {
        let defaults = UserDefaults.standard
        if defaultsKey == WorkspaceTabColorSettings.paletteKey {
            switch backup {
            case .absent:
                WorkspaceTabColorSettings.reset(defaults: defaults)
            case .stringDictionary(let value):
                WorkspaceTabColorSettings.persistPaletteMap(value, defaults: defaults)
            default:
                break
            }
            return
        }

        switch backup {
        case .absent:
            defaults.removeObject(forKey: defaultsKey)
        case .bool(let value):
            defaults.set(value, forKey: defaultsKey)
        case .int(let value):
            defaults.set(value, forKey: defaultsKey)
        case .double(let value):
            defaults.set(value, forKey: defaultsKey)
        case .string(let value):
            defaults.set(value, forKey: defaultsKey)
        case .stringArray(let value):
            defaults.set(value, forKey: defaultsKey)
        case .stringDictionary(let value):
            defaults.set(value, forKey: defaultsKey)
        }

        if defaultsKey == TerminalScrollBarSettings.showScrollBarKey {
            TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
        }

        switch defaultsKey {
        case LanguageSettings.languageKey:
            let language = AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
            LanguageSettings.apply(language)
        case AppearanceSettings.appearanceModeKey:
            AppearanceSettings.applyStoredMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey), source: "cmuxConfig.restoreUserDefault")
        case AppIconSettings.modeKey:
            AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
        default:
            break
        }
    }

    private func loadBackups() -> [String: BackupValue] {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: Self.backupsDefaultsKey),
              let backups = try? JSONDecoder().decode([String: BackupValue].self, from: data) else {
            return [:]
        }
        return backups
    }

    private func saveBackups(_ backups: [String: BackupValue]) {
        let defaults = UserDefaults.standard
        if backups.isEmpty {
            defaults.removeObject(forKey: Self.backupsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(backups) else { return }
        defaults.set(data, forKey: Self.backupsDefaultsKey)
    }

    private func logInvalid(_ path: String, sourcePath: String) {
        NSLog("[CmuxSettingsFileStore] ignoring invalid setting '%@' in %@", path, sourcePath)
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
            uniqueKeysWithValues: KeyboardShortcutSettings.Action.allCases.map { action in
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
                    "showModifierHoldHints": ShortcutHintDebugSettings.defaultShowHintsOnCommandHold &&
                        ShortcutHintDebugSettings.defaultShowHintsOnControlHold,
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

    private static func prettyJSONString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

typealias KeyboardShortcutSettingsFileStore = CmuxSettingsFileStore

private struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var managedCustomSettings = ManagedCustomSettings()

    mutating func fillMissingSettings(from fallback: ResolvedSettingsSnapshot) {
        if path == nil && (!fallback.shortcuts.isEmpty ||
            !fallback.managedUserDefaults.isEmpty ||
            !fallback.managedCustomSettings.isEmpty) {
            path = fallback.path
        }
        for (action, shortcut) in fallback.shortcuts where shortcuts[action] == nil {
            shortcuts[action] = shortcut
        }
        for (key, value) in fallback.managedUserDefaults where managedUserDefaults[key] == nil {
            managedUserDefaults[key] = value
        }
        managedCustomSettings.fillMissingSettings(from: fallback.managedCustomSettings)
    }
}

private enum ManagedStringOverride: Equatable {
    case set(String)
    case clear
}

private struct ManagedCustomSettings: Equatable {
    var socketPassword: ManagedStringOverride?

    var isEmpty: Bool {
        socketPassword == nil
    }

    var managedIdentifiers: Set<String> {
        var identifiers: Set<String> = []
        if socketPassword != nil {
            identifiers.insert(CmuxSettingsFileStore.socketPasswordBackupIdentifier)
        }
        return identifiers
    }

    mutating func fillMissingSettings(from fallback: ManagedCustomSettings) {
        if socketPassword == nil {
            socketPassword = fallback.socketPassword
        }
    }
}

private enum ManagedSettingsValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case nullableString(String?)
    case stringArray([String])
    case stringDictionary([String: String])
}

private enum BackupValue: Codable, Equatable {
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

private final class ShortcutSettingsFileWatcher {
    private let path: String
    private let fileManager: FileManager
    private let onChange: () -> Void
    private let watchQueue = DispatchQueue(label: "com.cmux.shortcut-settings-file-watch")

    private var source: DispatchSourceFileSystemObject?

    init(path: String, fileManager: FileManager = .default, onChange: @escaping () -> Void) {
        self.path = path
        self.fileManager = fileManager
        self.onChange = onChange
        start()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func start() {
        stop()

        if fileManager.fileExists(atPath: path) {
            startFileWatcher()
        } else {
            startDirectoryWatcher()
        }
    }

    private func startFileWatcher() {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            startDirectoryWatcher()
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.start()
            }
            self.onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }

    private func startDirectoryWatcher() {
        let directoryPath = (path as NSString).deletingLastPathComponent
        let fd = open(directoryPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.path) {
                self.start()
            } else {
                self.onChange()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }
}
