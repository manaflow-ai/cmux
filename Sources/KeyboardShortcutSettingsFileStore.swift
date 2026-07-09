import CMUXAgentLaunch
import Combine
import CmuxFoundation
import CmuxSettings
import Foundation
import os

nonisolated private let cmuxSettingsFileStoreLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

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

    /// The default settings-file locations, resolved by the
    /// ``SettingsFileLocations`` value type in `CmuxSettings`. The app supplies
    /// the release bundle identifier from `CmuxGhosttyConfigPathResolver`; the
    /// three accessors below forward each resolved path so the existing API and
    /// call sites stay unchanged.
    private static var defaultSettingsFileLocations: SettingsFileLocations {
        SettingsFileLocations(
            releaseBundleIdentifier: CmuxGhosttyConfigPathResolver.releaseBundleIdentifier
        )
    }

    static var defaultPrimaryPath: String {
        defaultSettingsFileLocations.primaryPath
    }

    static var defaultFallbackPath: String? {
        defaultSettingsFileLocations.fallbackPath
    }

    static var defaultApplicationSupportFallbackPath: String? {
        defaultSettingsFileLocations.applicationSupportFallbackPath
    }

    private let primaryPath: String
    private let fallbackPaths: [String]
    private let fileManager: FileManager
    private let notificationCenter: NotificationCenter
    private let passwordStore: SocketControlPasswordStore
    private let appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment
    private let reader: SettingsFileReader
    private let managedDefaultsRepository = ManagedDefaultsRepository(defaults: .standard)
    private let managedDefaultsBackupService: ManagedDefaultsBackupService
    private let managedDefaultsApplicator: ManagedDefaultsApplicator
    private let managedDefaultSideEffectApplier: ManagedDefaultSideEffectApplier
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
        let paletteSeam = WorkspaceTabColorPaletteSeam()
        self.managedDefaultsBackupService = ManagedDefaultsBackupService(
            defaults: .standard,
            passwordStore: passwordStore,
            paletteSeam: paletteSeam
        )
        self.managedDefaultsApplicator = ManagedDefaultsApplicator(paletteSeam: paletteSeam)
        self.managedDefaultSideEffectApplier = ManagedDefaultSideEffectApplier(
            notificationCenter: notificationCenter,
            appearanceEnvironment: appearanceEnvironment
        )
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
        managedDefaultSideEffectApplier.applyManagedDefaultBatchSideEffects(drainDeferredManagedDefaultSideEffects())
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
                backups[defaultsKey] = managedDefaultsBackupService.backupValue(forUserDefaultsKey: defaultsKey, managedValue: value)
            }
            if snapshot.managedCustomSettings.socketPassword != nil,
               backups[ManagedDefaultBackupValue.socketPasswordBackupIdentifier] == nil {
                backups[ManagedDefaultBackupValue.socketPasswordBackupIdentifier] = managedDefaultsBackupService.currentSocketPasswordBackupValue()
            }
        }

        for identifier in currentManagedIdentifiers.subtracting(nextManagedIdentifiers) {
            guard let backup = backups[identifier] else { continue }
            sideEffects.merge(
                managedDefaultsBackupService.restoreBackup(
                    backup,
                    for: identifier,
                    synchronizeManagedAppearanceTerminalTheme: synchronizeManagedAppearanceTerminalTheme
                )
            )
            backups.removeValue(forKey: identifier)
        }

        for (defaultsKey, value) in snapshot.managedUserDefaults {
            sideEffects.merge(
                managedDefaultsApplicator.applyManagedUserDefaultsValue(
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
            managedDefaultSideEffectApplier.applyManagedDefaultBatchSideEffects(sideEffectsToApply)
        } else {
            deferManagedDefaultSideEffects(managedDefaultSideEffectApplier.applyLaunchManagedDefaultSideEffects(sideEffects))
        }
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

