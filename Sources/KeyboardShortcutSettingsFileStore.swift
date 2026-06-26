import CMUXAgentLaunch
import Combine
import CmuxFoundation
import CmuxSettings
import Foundation
import Observation
import os

nonisolated private let cmuxSettingsFileStoreLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    private(set) var revision: UInt64 = 0

    /// Composition-root-owned single instance, recorded once at startup.
    /// `nonisolated(unsafe)`: written exactly once in
    /// ``AppDelegate/configure`` (with the cmuxApp-owned `@State`)
    /// before any concurrent reader exists. Retires together with the
    /// transitional ``shared`` accessor once every view site is injected.
    nonisolated(unsafe) private static var compositionRootInstance: KeyboardShortcutSettingsObserver?

    /// The single instance, lazily constructed on first access. The cmuxApp
    /// `@State` resolves this through ``shared`` and `AppDelegate`
    /// installs the same object as the composition-root instance, so there is
    /// exactly one observer (revision counter) across every consumer.
    private static let instance = KeyboardShortcutSettingsObserver()

    /// Transitional accessor for the de-singletonization (CONVENTIONS §5
    /// `static let shared` → construct-and-inject). The type no longer
    /// self-vivifies an eager `static let shared`; the cmuxApp `@State`
    /// owns the single instance and injects it into `AppDelegate` (which records
    /// ownership via ``installCompositionRootInstance(_:)``). The SwiftUI view
    /// sites (`ContentView`, `WorkspaceContentView`, `RightSidebarPanelView`,
    /// `NotificationsPage`, `BrowserPanelView`, `UpdateTitlebarAccessory`) still
    /// reach the same single object here while they are migrated to an injected
    /// reference; dropping ``shared`` is the end state.
    static var shared: KeyboardShortcutSettingsObserver {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` (in `configure`, with the cmuxApp-owned
    /// `@State`) to record composition-root ownership of the single
    /// instance. Idempotent (keeps the first installed instance).
    static func installCompositionRootInstance(_ instance: KeyboardShortcutSettingsObserver) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        for name in [KeyboardShortcutSettings.didChangeNotification, KeyboardShortcutRecorderActivity.didChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.revision &+= 1 }
            })
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}

final class CmuxSettingsFileStore {
    /// Composition-root-owned single instance, recorded once at startup.
    /// `nonisolated(unsafe)`: written exactly once in ``AppDelegate/configure``
    /// (with the instance held by `KeyboardShortcutSettings.settingsFileStore`)
    /// before any concurrent reader exists, then only read. Retires together with
    /// the transitional ``shared`` accessor once the settings-file store is a
    /// constructor-injected dependency rather than a static singleton.
    nonisolated(unsafe) private static var compositionRootInstance: CmuxSettingsFileStore?

    /// The single instance, lazily constructed on first access. The sole
    /// production consumer (`KeyboardShortcutSettings.settingsFileStore`, seeded
    /// with ``shared``) resolves this, and ``AppDelegate/configure`` installs the
    /// same object as the composition-root instance, so there is exactly one
    /// settings-file store.
    private static let instance = CmuxSettingsFileStore()

    /// Transitional accessor for the de-singletonization (CONVENTIONS §5
    /// `static let shared` → construct-and-inject). The type no longer
    /// self-vivifies an eager `static let shared`; the composition root records
    /// ownership of the single instance via ``installCompositionRootInstance(_:)``
    /// in `AppDelegate.configure`. The one remaining production consumer
    /// (`KeyboardShortcutSettings.settingsFileStore`) seeds itself from here while
    /// it is migrated to an injected reference; dropping ``shared`` is the end
    /// state.
    static var shared: CmuxSettingsFileStore {
        compositionRootInstance ?? instance
    }

    /// Called once by ``AppDelegate`` (in `configure`, with the instance held by
    /// `KeyboardShortcutSettings.settingsFileStore`) to record composition-root
    /// ownership of the single instance. Idempotent (keeps the first installed
    /// instance).
    static func installCompositionRootInstance(_ instance: CmuxSettingsFileStore) {
        guard compositionRootInstance == nil else { return }
        compositionRootInstance = instance
    }

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
            .appendingPathComponent(CmuxGhosttyConfigPathResolver.releaseBundleIdentifier, isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
            .path
    }

    private let primaryPath: String
    private let fallbackPaths: [String]
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let passwordStore: SocketControlPasswordStore
    private let appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment
    private let reader: SettingsFileReader
    private let managedDefaultsRepository = ManagedDefaultsRepository(defaults: .standard)
    private let stateLock = NSLock()

    private var watchers: [FileWatcher] = []
    private var watchTasks: [Task<Void, Never>] = []
    private var defaultsCancellable: AnyCancellable?
    private var socketPasswordObserver: NSObjectProtocol?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var whenClausesByAction: [KeyboardShortcutSettings.Action: ShortcutWhenClause] = [:]
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
        self.reader = SettingsFileReader(
            primaryPath: self.primaryPath,
            fallbackPaths: self.fallbackPaths,
            fileManager: self.fileManager
        )
        importedManagedDefaults = loadImportedManagedDefaults()

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
                importedManagedDefaults: importedManagedDefaults,
                sourcePath: activeSourcePath
            )
        }
        let resolved = reader.resolveSettings()
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
            activeManagedUserDefaults = resolved.managedUserDefaults
            importedManagedDefaults = resolved.managedUserDefaults
            activeLegacyDerivedManagedUserDefaultKeys = resolved.legacyDerivedManagedUserDefaultKeys
            activeManagedCustomSettings = resolved.managedCustomSettings
            activeSourcePath = resolved.path
        }
        saveImportedManagedDefaults(resolved.managedUserDefaults)

        if previousState.shortcuts != resolved.shortcuts
            || previousState.whenClauses != resolved.whenClauses
            || previousState.sourcePath != resolved.path {
            KeyboardShortcutSettings.notifySettingsFileDidChange(center: notificationCenter)
        }
    }

    func override(for action: KeyboardShortcutSettings.Action) -> StoredShortcut? {
        synchronized { shortcutsByAction[action] }
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
            guard case .parsed = reader.loadSettings(at: fallbackPath) else {
                continue
            }
            guard let source = String(data: data, encoding: .utf8) else {
                return data
            }
            let updated = source.replacingOccurrences(of: CmuxSettingsFileSchema.current.legacySchemaURLString, with: CmuxSettingsFileSchema.current.schemaURLString)
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

    private func applyManagedSettings(
        snapshot: ResolvedSettingsSnapshot,
        importedManagedDefaults: [String: ManagedSettingsValue],
        changedManagedDefaultKeys: Set<String>,
        updateBackups: Bool = true,
        applyLiveDefaultSideEffects: Bool,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) {
        var backups = managedDefaultsRepository.loadBackups()
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
               backups[ManagedDefaultBackupValue.socketPasswordBackupIdentifier] == nil {
                backups[ManagedDefaultBackupValue.socketPasswordBackupIdentifier] = currentSocketPasswordBackupValue()
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
            managedDefaultsRepository.saveBackups(backups)
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
        _ backup: ManagedDefaultBackupValue,
        for identifier: String,
        synchronizeManagedAppearanceTerminalTheme: Bool
    ) -> ManagedDefaultBatchSideEffects {
        switch identifier {
        case ManagedDefaultBackupValue.socketPasswordBackupIdentifier:
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

    private func backupValueForUserDefaultsKey(_ defaultsKey: String, managedValue: ManagedSettingsValue) -> ManagedDefaultBackupValue {
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

    private func currentSocketPasswordBackupValue() -> ManagedDefaultBackupValue {
        guard let current = try? passwordStore.loadPassword() else {
            return .absent
        }
        return .string(current)
    }

    private func restoreUserDefaultsBackup(
        _ backup: ManagedDefaultBackupValue,
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
                } else if change.defaultsKey == AppCatalogSection().appIcon.userDefaultsKey {
                    // `apply` runs only on the main thread (gated below), so the
                    // `@MainActor` applier is safe to enter here.
                    MainActor.assumeIsolated { appIconApplier.applyResolvedMode() }
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

    // Pure decode/encode of the imported-managed-defaults and backups caches now
    // lives in ``ManagedDefaultsRepository`` (CmuxSettings). This file keeps only
    // the app-coupled legacy-migration tail and retired-key cleanup, which read
    // app-target setting catalogs the package cannot reference.

    private func loadImportedManagedDefaults() -> [String: ManagedSettingsValue] {
        let defaults = UserDefaults.standard
        var imported = managedDefaultsRepository.loadImportedManagedDefaults()

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
        UserDefaults.standard.removeObject(forKey: SidebarMatchTerminalBackgroundSettings.legacyAppliedSettingsFileDefaultKey)
        managedDefaultsRepository.saveImportedManagedDefaults(imported)
    }

}

typealias KeyboardShortcutSettingsFileStore = CmuxSettingsFileStore

