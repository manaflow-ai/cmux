import Darwin
import Foundation

enum SettingsJSONPersistenceSource: Sendable {
    case userDefaults
    case custom
}

struct PendingSettingsJSONValue: Equatable, Sendable {
    let value: ManagedSettingsValue
    let source: SettingsJSONPersistenceSource
}

struct SettingsJSONPersistenceRollback: Sendable {
    let previousValues: [String: ManagedSettingsValue]
    let missingPreviousPaths: Set<String>
}

struct ResolvedSettingsSnapshot {
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

final class ShortcutSettingsFileWatcher {
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
            }
            self.onChange()
        }

        source.setCancelHandler {
            close(fd)
        }

        self.source = source
        source.resume()
    }
}
