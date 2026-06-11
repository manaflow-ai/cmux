import Combine
import CmuxFileWatch
import CmuxSocketControl
import Foundation
import Observation
import os

nonisolated let cmuxSettingsFileStoreLogger = Logger(subsystem: "com.cmuxterm.app", category: "SettingsStore")

@MainActor
@Observable
final class KeyboardShortcutSettingsObserver {
    static let shared = KeyboardShortcutSettingsObserver()

    private(set) var revision: UInt64 = 0

    @ObservationIgnored private var settingsCancellable: AnyCancellable?
    @ObservationIgnored private var recorderCancellable: AnyCancellable?

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
    static let backupsDefaultsKey = "cmux.settingsFile.backups.v1"
    static let importedManagedDefaultsDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    static let socketPasswordBackupIdentifier = "automation.socketPassword"

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
    let notificationCenter: NotificationCenter
    let passwordStore: SocketControlPasswordStore
    let appearanceEnvironment: AppearanceSettings.LiveApplyEnvironment
    private let stateLock = NSLock()

    private var watchers: [FileWatcher] = []
    private var watchTasks: [Task<Void, Never>] = []
    private var defaultsCancellable: AnyCancellable?
    private var socketPasswordObserver: NSObjectProtocol?

    private var shortcutsByAction: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    private var activeManagedUserDefaults: [String: ManagedSettingsValue] = [:]
    private var importedManagedDefaults: [String: ManagedSettingsValue] = [:]
    private var activeLegacyDerivedManagedUserDefaultKeys: Set<String> = []
    private var activeManagedCustomSettings = ManagedCustomSettings()
    var isApplyingManagedSettings = false
    var deferredManagedDefaultSideEffects = ManagedDefaultBatchSideEffects()
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
            activeManagedUserDefaults = resolved.managedUserDefaults
            importedManagedDefaults = resolved.managedUserDefaults
            activeLegacyDerivedManagedUserDefaultKeys = resolved.legacyDerivedManagedUserDefaultKeys
            activeManagedCustomSettings = resolved.managedCustomSettings
            activeSourcePath = resolved.path
        }
        saveImportedManagedDefaults(resolved.managedUserDefaults)

        if previousState.shortcuts != resolved.shortcuts || previousState.sourcePath != resolved.path {
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

    func synchronized<T>(_ body: () -> T) -> T {
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

}

typealias KeyboardShortcutSettingsFileStore = CmuxSettingsFileStore

struct ResolvedSettingsSnapshot {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var legacyDerivedManagedUserDefaultKeys: Set<String> = []
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
            if fallback.legacyDerivedManagedUserDefaultKeys.contains(key) {
                legacyDerivedManagedUserDefaultKeys.insert(key)
            }
        }
        managedCustomSettings.fillMissingSettings(from: fallback.managedCustomSettings)
    }
}

struct ManagedDefaultSideEffect {
    let defaultsKey: String
    let source: String
    let synchronizeAppearanceTerminalTheme: Bool
}

struct ManagedDefaultBatchSideEffects {
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

enum ManagedStringOverride: Equatable {
    case set(String)
    case clear
}

struct ManagedCustomSettings: Equatable {
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

enum ManagedSettingsValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case nullableString(String?)
    case stringArray([String])
    case stringDictionary([String: String])
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
