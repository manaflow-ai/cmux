import Combine
import CmuxFoundation
import CmuxSettings
import Foundation
import os

nonisolated private let cmuxSettingsFileStoreLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

@MainActor
final class KeyboardShortcutSettingsObserver: ObservableObject {
    static let shared = KeyboardShortcutSettingsObserver()

    @Published private(set) var revision: UInt64 = 0

    private var settingsCancellable: AnyCancellable?
    private var recorderCancellable: AnyCancellable?

    private init(notificationCenter: NotificationCenter = .default) {
        settingsCancellable = notificationCenter.publisher(for: KeyboardShortcutSettings.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision &+= 1 }
        recorderCancellable = notificationCenter.publisher(for: KeyboardShortcutRecorderActivity.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.revision &+= 1 }
    }
}

final class CmuxSettingsFileStore {
    static let shared = CmuxSettingsFileStore()

    static let currentSchemaVersion = 1
    static let schemaURLString = "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json"
    private static let legacySchemaURLString = "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux-settings.schema.json"
    private static let releaseBundleIdentifier = "com.cmuxterm.app"
    private static let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
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
    private let passwordStore: SocketControlPasswordStore
    private let appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment
    private let stateLock = NSLock()

    private var watchers: [FileWatcher] = []
    private var watchTasks: [Task<Void, Never>] = []
    private var defaultsCancellable: AnyCancellable?
    private var socketPasswordObserver: NSObjectProtocol?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var whenClausesByAction: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [:]
    private var commandShortcutsByCommandId: [String: StoredShortcut] = [:]
    /// Prefiltered (non-unbound), deterministically ordered (by command id)
    /// snapshot of ``commandShortcutsByCommandId``, recomputed once per reload so
    /// the per-event keyboard dispatcher (`firstMatchingCommandShortcut`) can
    /// iterate a ready array instead of filtering + sorting on every keystroke.
    private var commandShortcutsOrderedSnapshot: [(commandId: String, shortcut: StoredShortcut)] = []
    private var activeManagedUserDefaults: [String: ManagedSettingsValue] = [:]
    private var importedManagedDefaults: [String: ManagedSettingsValue] = [:]
    private var activeLegacyDerivedManagedUserDefaultKeys: Set<String> = []
    private var activeManagedCustomSettings = ManagedCustomSettings()
    private var isApplyingManagedSettings = false
    private var deferredManagedDefaultSideEffects = ManagedDefaultBatchSideEffects()
    private(set) var activeSourcePath: String?

    init(
        primaryPath: String = CmuxSettingsFileStore.defaultPrimaryPath,
        fallbackPath: String? = CmuxSettingsFileStore.defaultFallbackPath,
        additionalFallbackPaths: [String] = [CmuxSettingsFileStore.defaultApplicationSupportFallbackPath].compactMap { $0 },
        fileManager: FileManager = .default,
        notificationCenter: NotificationCenter = .default,
        appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment = .live,
        passwordStore: SocketControlPasswordStore = SocketControlPasswordStore(),
        startWatching: Bool = true
    ) {
        self.primaryPath = primaryPath
        self.fallbackPaths = ([fallbackPath].compactMap { $0 } + additionalFallbackPaths)
            .filter { $0 != primaryPath }
        self.fileManager = fileManager
        self.notificationCenter = notificationCenter
        self.appearanceEnvironment = appearanceEnvironment
        self.passwordStore = passwordStore
        importedManagedDefaults = Self.loadImportedManagedDefaults()

        bootstrapPrimaryTemplateIfNeeded()
        // The app init path loads cmux.json before applying language/appearance
        // itself. Running live default side effects here can initialize UI/runtime
        // singletons while this store singleton is still in its dispatch_once.
        reload(
            applyLiveDefaultSideEffects: false,
            synchronizeManagedAppearanceTerminalTheme: false
        )
        guard startWatching else { return }

        watchers = ([primaryPath] + fallbackPaths).map { FileWatcher(path: $0) }
        watchTasks = watchers.map { watcher in
            let events = watcher.events
            return Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.reload()
                }
            }
        }

        defaultsCancellable = notificationCenter.publisher(for: UserDefaults.didChangeNotification).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reapplyManagedSettingsIfNeeded() }
        socketPasswordObserver = notificationCenter.addObserver(forName: SocketControlPasswordStore.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reapplyManagedSettingsIfNeeded()
        }
    }

    deinit {
        watchTasks.forEach { $0.cancel() }
        // Dropping the watchers runs each deinit, cancelling its DispatchSources.
        watchers.removeAll()
        defaultsCancellable?.cancel()
        if let socketPasswordObserver {
            notificationCenter.removeObserver(socketPasswordObserver)
        }
    }

    func reload() {
        reload(
            applyLiveDefaultSideEffects: true,
            synchronizeManagedAppearanceTerminalTheme: true
        )
    }

    func applyDeferredManagedDefaultSideEffects() {
        applyManagedDefaultBatchSideEffects(drainDeferredManagedDefaultSideEffects())
    }

    private func reload(
        applyLiveDefaultSideEffects: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) {
        let previousState = synchronized {
            (
                shortcuts: shortcutsByAction,
                whenClauses: whenClausesByAction,
                commandShortcuts: commandShortcutsByCommandId,
                importedManagedDefaults: importedManagedDefaults,
                sourcePath: activeSourcePath
            )
        }
        let resolved = resolveSettings()
        applyManagedSettings(
            snapshot: resolved,
            importedManagedDefaults: previousState.importedManagedDefaults,
            changedManagedDefaultKeys: newOrChangedManagedDefaultKeys(
                previous: previousState.importedManagedDefaults,
                next: resolved.managedUserDefaults
            ),
            applyLiveDefaultSideEffects: applyLiveDefaultSideEffects,
            synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
        )
        synchronized {
            shortcutsByAction = resolved.shortcuts
            whenClausesByAction = resolved.whenClauses
            commandShortcutsByCommandId = resolved.commandShortcuts
            commandShortcutsOrderedSnapshot = resolved.commandShortcuts
                .filter { !$0.value.isUnbound }
                .sorted { $0.key < $1.key }
                .map { (commandId: $0.key, shortcut: $0.value) }
            activeManagedUserDefaults = resolved.managedUserDefaults
            importedManagedDefaults = resolved.managedUserDefaults
            activeLegacyDerivedManagedUserDefaultKeys = resolved.legacyDerivedManagedUserDefaultKeys
            activeManagedCustomSettings = resolved.managedCustomSettings
            activeSourcePath = resolved.path
        }
        saveImportedManagedDefaults(resolved.managedUserDefaults)

        if previousState.shortcuts != resolved.shortcuts
            || previousState.whenClauses != resolved.whenClauses
            || previousState.commandShortcuts != resolved.commandShortcuts
            || previousState.sourcePath != resolved.path {
            KeyboardShortcutSettings.notifySettingsFileDidChange(center: notificationCenter)
        }
    }

    func override(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        synchronized { shortcutsByAction[action] }
    }

    /// User-assigned Command Palette command shortcuts (`shortcuts.commands`),
    /// keyed by command id. Entries that resolve to ``StoredShortcut/unbound``
    /// are dropped so the dispatcher only sees live single-stroke bindings.
    func commandShortcuts() -> [String: StoredShortcut] {
        synchronized {
            commandShortcutsByCommandId.filter { !$0.value.isUnbound }
        }
    }

    /// The prefiltered, deterministically ordered command-shortcut snapshot for
    /// the per-event keyboard dispatcher. Computed once per reload; reading it is
    /// a single lock-guarded copy-on-write array fetch (no per-keystroke filter
    /// or sort).
    func commandShortcutsOrderedList() -> [(commandId: String, shortcut: StoredShortcut)] {
        synchronized { commandShortcutsOrderedSnapshot }
    }

    /// The `when`-clause override for an action parsed from `shortcuts.when` in
    /// cmux.json, or `nil` when the action has no configured override (so the
    /// caller falls back to the action's built-in ``shortcutContext``).
    func whenClause(for action: KeyboardShortcutSettings.Action) -> ShortcutWhenClause? {
        synchronized { whenClausesByAction[action] }
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
            cmuxSettingsFileStoreLogger.warning("failed to bootstrap \(self.primaryPath, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))")
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
        let managedState: (snapshot: ResolvedSettingsSnapshot, importedManagedDefaults: [String: ManagedSettingsValue])? = synchronized {
            guard !isApplyingManagedSettings else { return nil }
            if activeManagedUserDefaults.isEmpty && activeManagedCustomSettings.isEmpty {
                return nil
            }
            return (
                ResolvedSettingsSnapshot(
                    path: activeSourcePath,
                    shortcuts: shortcutsByAction,
                    whenClauses: whenClausesByAction,
                    managedUserDefaults: activeManagedUserDefaults,
                    legacyDerivedManagedUserDefaultKeys: activeLegacyDerivedManagedUserDefaultKeys,
                    managedCustomSettings: activeManagedCustomSettings
                ),
                importedManagedDefaults
            )
        }
        guard let managedState else { return }
        applyManagedSettings(
            snapshot: managedState.snapshot,
            importedManagedDefaults: managedState.importedManagedDefaults,
            changedManagedDefaultKeys: [],
            updateBackups: false,
            applyLiveDefaultSideEffects: true,
            synchronizeManagedAppearanceTerminalTheme: true
        )
    }

    private func synchronized<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    // Only keys present in the next snapshot can force-apply; removed keys restore backups instead.
    private func newOrChangedManagedDefaultKeys(
        previous: [String: ManagedSettingsValue],
        next: [String: ManagedSettingsValue]
    ) -> Set<String> {
        Set(next.compactMap { key, value in
            previous[key] == value ? nil : key
        })
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
            cmuxSettingsFileStoreLogger.warning("parse error at \(path, privacy: .private(mask: .hash)): \(String(describing: error), privacy: .private(mask: .hash))")
            return .invalid
        }
    }

    private func parseSettingsFile(root: [String: Any], sourcePath: String) -> ResolvedSettingsSnapshot {
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
            snapshot.managedUserDefaults[AppIconSettings.modeKey] = .string(mode.rawValue)
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
        if let value = jsonInt(section["globalFontMagnification"]) {
            let clamped = GlobalFontMagnification.clamp(value)
            guard clamped == value else {
                logInvalid("app.globalFontMagnification", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[GlobalFontMagnification.percentKey] = .int(clamped)
        } else if section.keys.contains("globalFontMagnification") {
            logInvalid("app.globalFontMagnification", sourcePath: sourcePath)
        }
        if let raw = jsonString(section["forkConversationDefaultDestination"]) {
            if let destination = AgentConversationForkDestination(rawValue: raw) {
                snapshot.managedUserDefaults[AgentConversationForkDefaultSettings.key] = .string(destination.rawValue)
            } else {
                logInvalid("app.forkConversationDefaultDestination", sourcePath: sourcePath)
            }
        }
        applyBooleanSettings(AppSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyStringSettings(AppSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
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
        applyBooleanSettings(NotificationSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        if let raw = jsonString(section["sound"]) {
            let allowed = Set(NotificationSoundSettings.systemSounds.map(\.value))
            guard allowed.contains(raw) else {
                logInvalid("notifications.sound", sourcePath: sourcePath)
                return
            }
            snapshot.managedUserDefaults[NotificationSoundSettings.key] = .string(raw)
        }
        applyStringSettings(NotificationSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
    }

    private func parseTerminalSection(
        _ section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        applyBooleanSettings(TerminalSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyTerminalScrollSpeedSetting(from: section, assign: { snapshot.managedUserDefaults[$0] = .double($1) }, logInvalid: { logInvalid($0, sourcePath: sourcePath) })
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
        applyBooleanSettings(AutomationSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyStringSettings(AutomationSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
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
        applyBooleanSettings(BrowserSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
        applyStringSettings(BrowserSettingsFileMapping.stringSettings, from: section, snapshot: &snapshot)
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
        applyNormalizedStringArraySettings(BrowserSettingsFileMapping.stringArraySettings, from: section, sourcePath: sourcePath, snapshot: &snapshot)
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
        for (key, rawValue) in section
        where key != "bindings" && key != "showModifierHoldHints" && key != "when" && key != "commands" {
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

        parseShortcutWhenClauses(section["when"], sourcePath: sourcePath, snapshot: &snapshot)
        parseCommandShortcuts(section["commands"], sourcePath: sourcePath, snapshot: &snapshot)
    }

    /// Parses the optional `shortcuts.commands` map — `{ "<commandId>":
    /// "<shortcut>" }` — into per-command-id ``StoredShortcut`` overrides.
    /// Each binding is **single-stroke only**: a chord (two-element array or a
    /// `second` stroke) is rejected so a custom command shortcut can never
    /// silently shadow a tmux-style built-in chord. `null` / `"none"` etc. map
    /// to ``StoredShortcut/unbound`` (an explicit clear). Invalid entries are
    /// logged and skipped.
    private func parseCommandShortcuts(
        _ rawValue: Any?,
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let rawValue else { return }
        guard let commandsSection = rawValue as? [String: Any] else {
            logInvalid("shortcuts.commands", sourcePath: sourcePath)
            return
        }
        for (commandId, rawBinding) in commandsSection {
            guard !commandId.isEmpty else { continue }
            guard let shortcut = parseCommandShortcutValue(rawBinding) else {
                cmuxSettingsFileStoreLogger.warning("ignoring invalid shortcuts.commands binding for '\(commandId, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.commandShortcuts[commandId] = shortcut
        }
    }

    /// Decodes one `shortcuts.commands` value into a single-stroke
    /// ``StoredShortcut``. Accepts a string (`"cmd+shift+v"`), the package's
    /// nested object form (`{ "first": { … } }`), or an explicit unbind marker
    /// (`null` / `""` / `none` / …). A chord — a two-element string array or a
    /// non-null `second` stroke — is rejected (`nil`) so custom command
    /// shortcuts stay single-stroke.
    private func parseCommandShortcutValue(_ rawValue: Any) -> StoredShortcut? {
        if rawValue is NSNull { return .unbound }

        let shortcut: StoredShortcut
        if let stroke = jsonString(rawValue) {
            guard let parsed = StoredShortcut.parseConfig(stroke, allowBareFirstStroke: false) else {
                return nil
            }
            if parsed.isUnbound { return .unbound }
            if parsed.hasChord { return nil }
            shortcut = parsed
        } else if rawValue is [Any] {
            // A chord array is explicitly unsupported for command shortcuts.
            return nil
        } else if let object = rawValue as? [String: Any] {
            if let secondValue = object["second"], !(secondValue is NSNull) {
                return nil
            }
            guard let firstValue = object["first"],
                  let first = parseShortcutStrokeObject(firstValue) else {
                return nil
            }
            if first.key.isEmpty { return .unbound }
            shortcut = StoredShortcut(first: first)
        } else {
            return nil
        }

        // Command shortcuts must include a modifier: the Settings recorder
        // enforces it and the docs require it. `parseConfig`/the object form
        // still permit a bare Space, which would otherwise swallow ordinary
        // Space key events away from terminal/browser text input — reject any
        // first stroke without ⌘ ⌥ ⌃ or ⇧.
        guard !shortcut.firstStroke.modifierFlags.isEmpty else { return nil }
        return shortcut
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
                cmuxSettingsFileStoreLogger.warning("ignoring shortcuts.when for unknown action '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            guard let expression = jsonString(rawClause),
                  let clause = ShortcutWhenClause.parse(expression) else {
                cmuxSettingsFileStoreLogger.warning("ignoring invalid shortcuts.when clause for '\(rawAction, privacy: .private(mask: .hash))' in \(sourcePath, privacy: .private(mask: .hash))")
                continue
            }
            snapshot.whenClauses[action] = clause
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

    private func applyManagedSettings(
        snapshot: ResolvedSettingsSnapshot,
        importedManagedDefaults: [String: ManagedSettingsValue],
        changedManagedDefaultKeys: Set<String>,
        updateBackups: Bool = true,
        applyLiveDefaultSideEffects: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) {
        var backups = loadBackups()
        var sideEffects = ManagedDefaultBatchSideEffects()
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
            sideEffects.merge(
                restoreBackup(
                    backup,
                    for: identifier,
                    synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
                )
            )
            backups.removeValue(forKey: identifier)
        }

        for (defaultsKey, value) in snapshot.managedUserDefaults {
            sideEffects.merge(
                applyManagedUserDefaultsValue(
                    value,
                    for: defaultsKey,
                    importedDefault: importedManagedDefaults[defaultsKey],
                    forceApply: changedManagedDefaultKeys.contains(defaultsKey),
                    synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme,
                    isDerivedFromLegacyWarnBeforeQuit: snapshot.legacyDerivedManagedUserDefaultKeys.contains(defaultsKey),
                    importedLegacyWarnBeforeQuitDefault: importedManagedDefaults[AppCatalogSection().warnBeforeQuit.userDefaultsKey]
                )
            )
        }
        applyManagedCustomSettings(snapshot.managedCustomSettings)
        if updateBackups {
            saveBackups(backups)
        }
        if applyLiveDefaultSideEffects {
            var sideEffectsToApply = drainDeferredManagedDefaultSideEffects()
            sideEffectsToApply.merge(sideEffects)
            applyManagedDefaultBatchSideEffects(sideEffectsToApply)
        } else {
            deferManagedDefaultSideEffects(applyLaunchManagedDefaultSideEffects(sideEffects))
        }
    }

    private func applyLaunchManagedDefaultSideEffects(
        _ sideEffects: ManagedDefaultBatchSideEffects
    ) -> ManagedDefaultBatchSideEffects {
        var deferredSideEffects = ManagedDefaultBatchSideEffects()
        for change in sideEffects.changes {
            if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                AppearanceSettings.applyStoredMode(
                    rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                    source: change.source,
                    duringLaunch: true,
                    synchronizeTerminalTheme: false,
                    environment: appearanceEnvironment
                )
            } else {
                deferredSideEffects.append(
                    defaultsKey: change.defaultsKey,
                    source: change.source,
                    synchronizeAppearanceTerminalTheme: change.synchronizeAppearanceTerminalTheme
                )
            }
        }
        return deferredSideEffects
    }

    private func deferManagedDefaultSideEffects(_ sideEffects: ManagedDefaultBatchSideEffects) {
        guard !sideEffects.isEmpty else { return }
        synchronized {
            deferredManagedDefaultSideEffects.merge(sideEffects)
        }
    }

    private func drainDeferredManagedDefaultSideEffects() -> ManagedDefaultBatchSideEffects {
        synchronized {
            let deferred = deferredManagedDefaultSideEffects
            deferredManagedDefaultSideEffects = ManagedDefaultBatchSideEffects()
            return deferred
        }
    }

    private func applyManagedCustomSettings(_ settings: ManagedCustomSettings) {
        if let socketPassword = settings.socketPassword {
            switch socketPassword {
            case .set(let value):
                let current = (try? passwordStore.loadPassword()) ?? nil
                if current != value {
                    try? passwordStore.savePassword(value)
                }
            case .clear:
                let current = (try? passwordStore.loadPassword()) ?? nil
                if current != nil {
                    try? passwordStore.clearPassword()
                }
            }
        }
    }

    private func restoreBackup(
        _ backup: BackupValue,
        for identifier: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        switch identifier {
        case Self.socketPasswordBackupIdentifier:
            switch backup {
            case .string(let value):
                try? passwordStore.savePassword(value)
            case .absent:
                try? passwordStore.clearPassword()
            default:
                break
            }
            return ManagedDefaultBatchSideEffects()
        default:
            return restoreUserDefaultsBackup(
                backup,
                for: identifier,
                synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
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
        guard let current = try? passwordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func restoreUserDefaultsBackup(
        _ backup: BackupValue,
        for defaultsKey: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
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
            return ManagedDefaultBatchSideEffects()
        }

        var didMutateStoredValue = false
        switch backup {
        case .absent:
            if defaults.object(forKey: defaultsKey) != nil {
                defaults.removeObject(forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .bool(let value):
            if defaults.object(forKey: defaultsKey) as? Bool != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .int(let value):
            if defaults.object(forKey: defaultsKey) as? Int != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .double(let value):
            if defaults.object(forKey: defaultsKey) as? Double != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .string(let value):
            if defaults.string(forKey: defaultsKey) != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringArray(let value):
            if defaults.array(forKey: defaultsKey) as? [String] != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        case .stringDictionary(let value):
            if defaults.dictionary(forKey: defaultsKey) as? [String: String] != value {
                defaults.set(value, forKey: defaultsKey)
                didMutateStoredValue = true
            }
        }

        if didMutateStoredValue {
            return managedDefaultSideEffects(
                for: defaultsKey,
                source: "cmuxConfig.restoreUserDefault",
                synchronizeAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
        }
        return ManagedDefaultBatchSideEffects()
    }

    private func applyManagedUserDefaultsValue(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue?,
        forceApply: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool,
        isDerivedFromLegacyWarnBeforeQuit: Bool = false,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue? = nil
    ) -> ManagedDefaultBatchSideEffects {
        let defaults = UserDefaults.standard
        guard shouldApplyManagedUserDefaultsValue(
            value,
            for: defaultsKey,
            importedDefault: importedDefault,
            forceApply: forceApply,
            isDerivedFromLegacyWarnBeforeQuit: isDerivedFromLegacyWarnBeforeQuit,
            importedLegacyWarnBeforeQuitDefault: importedLegacyWarnBeforeQuitDefault,
            defaults: defaults
        ) else {
            return ManagedDefaultBatchSideEffects()
        }

        if defaultsKey == WorkspaceTabColorSettings.paletteKey,
           case .stringDictionary(let next) = value {
            let current = WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults)
            if current != next {
                WorkspaceTabColorSettings.persistPaletteMap(next, defaults: defaults)
            }
            return ManagedDefaultBatchSideEffects()
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

        if didMutateStoredValue {
            return managedDefaultSideEffects(
                for: defaultsKey,
                source: "cmuxConfig.applyManagedDefault",
                synchronizeAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
            )
        }
        return ManagedDefaultBatchSideEffects()
    }

    private func shouldApplyManagedUserDefaultsValue(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue?,
        forceApply: Bool,
        isDerivedFromLegacyWarnBeforeQuit: Bool,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue?,
        defaults: UserDefaults
    ) -> Bool {
        guard !forceApply else { return true }
        guard let importedDefault else { return true }
        // Precedence: user explicit choice (UserDefaults) > cmux.json imported default > built-in default.
        guard let current = currentManagedUserDefaultsValue(
            for: defaultsKey,
            matching: value,
            defaults: defaults
        ) else {
            return shouldApplyManagedUserDefaultsValueWhenCurrentIsMissing(
                value,
                for: defaultsKey,
                importedDefault: importedDefault,
                isDerivedFromLegacyWarnBeforeQuit: isDerivedFromLegacyWarnBeforeQuit,
                importedLegacyWarnBeforeQuitDefault: importedLegacyWarnBeforeQuitDefault,
                defaults: defaults
            )
        }
        return current == importedDefault
    }

    private func shouldApplyManagedUserDefaultsValueWhenCurrentIsMissing(
        _ value: ManagedSettingsValue,
        for defaultsKey: String,
        importedDefault: ManagedSettingsValue,
        isDerivedFromLegacyWarnBeforeQuit: Bool,
        importedLegacyWarnBeforeQuitDefault: ManagedSettingsValue?,
        defaults: UserDefaults
    ) -> Bool {
        if defaultsKey == AppCatalogSection().confirmQuitMode.userDefaultsKey,
           isDerivedFromLegacyWarnBeforeQuit,
           case .bool(let importedLegacyValue)? = importedLegacyWarnBeforeQuitDefault,
           let currentLegacyValue = defaults.object(forKey: AppCatalogSection().warnBeforeQuit.userDefaultsKey) as? Bool,
           currentLegacyValue != importedLegacyValue {
            return false
        }
        switch (value, importedDefault) {
        case (.nullableString, .nullableString(nil)):
            return true
        case (.nullableString, _):
            return false
        default:
            return true
        }
    }

    private func currentManagedUserDefaultsValue(
        for defaultsKey: String,
        matching value: ManagedSettingsValue,
        defaults: UserDefaults
    ) -> ManagedSettingsValue? {
        switch value {
        case .bool:
            guard let current = defaults.object(forKey: defaultsKey) as? Bool else { return nil }
            return .bool(current)
        case .int:
            guard let current = defaults.object(forKey: defaultsKey) as? Int else { return nil }
            return .int(current)
        case .double:
            guard let current = defaults.object(forKey: defaultsKey) as? Double else { return nil }
            return .double(current)
        case .string:
            guard let current = defaults.string(forKey: defaultsKey) else { return nil }
            return .string(current)
        case .nullableString:
            guard let current = defaults.object(forKey: defaultsKey) as? String else { return nil }
            return .nullableString(current)
        case .stringArray:
            guard let current = defaults.array(forKey: defaultsKey) as? [String] else { return nil }
            return .stringArray(current)
        case .stringDictionary:
            if defaultsKey == WorkspaceTabColorSettings.paletteKey {
                return .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults))
            }
            guard let current = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
                return nil
            }
            return .stringDictionary(current)
        }
    }

    private func managedDefaultSideEffects(
        for defaultsKey: String,
        source: String,
        synchronizeAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        var sideEffects = ManagedDefaultBatchSideEffects()
        sideEffects.append(
            defaultsKey: defaultsKey,
            source: source,
            synchronizeAppearanceTerminalTheme: synchronizeAppearanceTerminalTheme
        )
        return sideEffects
    }

    private func applyManagedDefaultBatchSideEffects(_ sideEffects: ManagedDefaultBatchSideEffects) {
        guard !sideEffects.isEmpty else { return }
        let notificationCenter = notificationCenter
        let changes = sideEffects.changes
        let apply = {
            var agentSessionAutoResumeDidChange = false
            var agentHibernationDidChange = false
            var rendererRealizationDidChange = false
            for change in changes {
                if change.defaultsKey == TerminalScrollBarSettings.showScrollBarKey {
                    TerminalScrollBarSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == TerminalCopyOnSelectSettings.copyOnSelectKey {
                    TerminalCopyOnSelectSettings.notifyDidChange(notificationCenter: notificationCenter)
                }

                if change.defaultsKey == AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey {
                    agentSessionAutoResumeDidChange = true
                }
                if change.defaultsKey == AgentHibernationSettings.enabledKey ||
                    change.defaultsKey == AgentHibernationSettings.idleSecondsKey ||
                    change.defaultsKey == AgentHibernationSettings.maxLiveTerminalsKey ||
                    change.defaultsKey == AgentHibernationSettings.confirmationSecondsKey {
                    agentHibernationDidChange = true
                }
                if change.defaultsKey == RendererRealizationSettings.enabledKey ||
                    change.defaultsKey == RendererRealizationSettings.idleSecondsKey ||
                    change.defaultsKey == RendererRealizationSettings.maxWarmRenderersKey {
                    rendererRealizationDidChange = true
                }

                if change.defaultsKey == AppCatalogSection().language.userDefaultsKey {
                    let rawValue = UserDefaults.standard.string(forKey: change.defaultsKey) ?? ""
                    LanguageSettingsStore(defaults: .standard).applyLanguageOverride(AppLanguage(rawValue: rawValue) ?? .system)
                } else if change.defaultsKey == AppearanceSettings.appearanceModeKey {
                    AppearanceSettings.applyStoredMode(
                        rawValue: UserDefaults.standard.string(forKey: change.defaultsKey),
                        source: change.source,
                        duringLaunch: !change.synchronizeAppearanceTerminalTheme,
                        synchronizeTerminalTheme: change.synchronizeAppearanceTerminalTheme,
                        environment: self.appearanceEnvironment
                    )
                } else if change.defaultsKey == AppIconSettings.modeKey {
                    AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
                } else if change.defaultsKey == GlobalFontMagnification.percentKey {
                    notificationCenter.post(name: GlobalFontMagnification.didChangeNotification, object: nil)
                }
            }

            if agentSessionAutoResumeDidChange {
                AgentSessionAutoResumeSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
            if agentHibernationDidChange {
                AgentHibernationSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
            if rendererRealizationDidChange {
                RendererRealizationSettings.notifyDidChange(notificationCenter: notificationCenter)
            }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async { apply() }
        }
    }

    private static func loadImportedManagedDefaults() -> [String: ManagedSettingsValue] {
        let defaults = UserDefaults.standard
        var imported: [String: ManagedSettingsValue]
        if let data = defaults.data(forKey: importedManagedDefaultsDefaultsKey),
           let decoded = try? JSONDecoder().decode([String: ManagedSettingsValue].self, from: data) {
            imported = decoded
        } else {
            imported = [:]
        }

        if imported[SidebarMatchTerminalBackgroundSettings.userDefaultsKey] == nil,
           let legacyValue = defaults.object(
               forKey: SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey
           ) as? Bool {
            imported[SidebarMatchTerminalBackgroundSettings.userDefaultsKey] = .bool(legacyValue)
        }
        if imported[AppCatalogSection().confirmQuitMode.userDefaultsKey] == nil,
           case .bool(let importedLegacyValue)? = imported[AppCatalogSection().warnBeforeQuit.userDefaultsKey] {
            imported[AppCatalogSection().confirmQuitMode.userDefaultsKey] = .string(
                (importedLegacyValue ? ConfirmQuitMode.always : .never).rawValue
            )
        }
        return imported
    }

    private func saveImportedManagedDefaults(_ imported: [String: ManagedSettingsValue]) {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey)
        guard !imported.isEmpty else {
            defaults.removeObject(forKey: Self.importedManagedDefaultsDefaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(imported) else { return }
        defaults.set(data, forKey: Self.importedManagedDefaultsDefaultsKey)
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

    private func applyBooleanSettings(
        _ settings: [SettingsFileBooleanMapping],
        from section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        for setting in settings {
            if let value = jsonBool(section[setting.jsonKey]) {
                snapshot.managedUserDefaults[setting.defaultsKey] = .bool(value)
            } else if let invalidPath = setting.invalidPath, section.keys.contains(setting.jsonKey) {
                logInvalid(invalidPath, sourcePath: sourcePath)
            }
        }
    }

    private func applyStringSettings(
        _ settings: [SettingsFileStringMapping],
        from section: [String: Any],
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        for setting in settings {
            if let raw = jsonString(section[setting.jsonKey]) {
                snapshot.managedUserDefaults[setting.defaultsKey] = .string(raw)
            }
        }
    }

    private func applyNormalizedStringArraySettings(
        _ settings: [SettingsFileStringArrayMapping],
        from section: [String: Any],
        sourcePath: String,
        snapshot: inout ResolvedSettingsSnapshot
    ) {
        for setting in settings {
            if let values = jsonStringArray(section[setting.jsonKey]) {
                let normalized = values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                snapshot.managedUserDefaults[setting.defaultsKey] = .string(normalized.joined(separator: "\n"))
            } else if section.keys.contains(setting.jsonKey) {
                logInvalid(setting.invalidPath, sourcePath: sourcePath)
            }
        }
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

typealias KeyboardShortcutSettingsFileStore = CmuxSettingsFileStore

private struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    /// Per-action `when`-clause overrides parsed from `shortcuts.when` — gate a
    /// binding to a focus context (see ``ShortcutWhenClause``).
    var whenClauses: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [:]
    /// User-assigned Command Palette command shortcuts parsed from
    /// `shortcuts.commands`, keyed by command id. Single-stroke only; the app
    /// dispatches a match on the focused window.
    var commandShortcuts: [String: StoredShortcut] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var legacyDerivedManagedUserDefaultKeys: Set<String> = []
    var managedCustomSettings = ManagedCustomSettings()

    mutating func fillMissingSettings(from fallback: ResolvedSettingsSnapshot) {
        if path == nil && (!fallback.shortcuts.isEmpty ||
            !fallback.commandShortcuts.isEmpty ||
            !fallback.managedUserDefaults.isEmpty ||
            !fallback.managedCustomSettings.isEmpty) {
            path = fallback.path
        }
        for (action, shortcut) in fallback.shortcuts where shortcuts[action] == nil {
            shortcuts[action] = shortcut
        }
        for (action, clause) in fallback.whenClauses where whenClauses[action] == nil {
            whenClauses[action] = clause
        }
        for (commandId, shortcut) in fallback.commandShortcuts where commandShortcuts[commandId] == nil {
            commandShortcuts[commandId] = shortcut
        }
        for (key, value) in fallback.managedUserDefaults where managedUserDefaults[key] == nil {
            managedUserDefaults[key] = value
            if fallback.legacyDerivedManagedUserDefaultKeys.contains(key) {
                legacyDerivedManagedUserDefaultKeys.insert(key)
            }
        }
        managedCustomSettings.fillMissingSettings(from: fallback.managedCustomSettings)
    }
}

private struct ManagedDefaultSideEffect {
    let defaultsKey: String
    let source: String
    let synchronizeAppearanceTerminalTheme: Bool
}

private struct ManagedDefaultBatchSideEffects {
    var changes: [ManagedDefaultSideEffect] = []

    var isEmpty: Bool {
        changes.isEmpty
    }

    mutating func merge(_ other: ManagedDefaultBatchSideEffects) {
        for change in other.changes {
            append(
                defaultsKey: change.defaultsKey,
                source: change.source,
                synchronizeAppearanceTerminalTheme: change.synchronizeAppearanceTerminalTheme
            )
        }
    }

    mutating func append(
        defaultsKey: String,
        source: String,
        synchronizeAppearanceTerminalTheme: Bool
    ) {
        changes.removeAll { $0.defaultsKey == defaultsKey }
        changes.append(
            ManagedDefaultSideEffect(
                defaultsKey: defaultsKey,
                source: source,
                synchronizeAppearanceTerminalTheme: synchronizeAppearanceTerminalTheme
            )
        )
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

private enum ManagedSettingsValue: Codable, Equatable {
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
