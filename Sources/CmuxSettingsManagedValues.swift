import Foundation
import os

private let cmuxSettingsLog = Logger(subsystem: "com.cmuxterm.app", category: "SettingsFile")

func logManagedSettingsWriteBackFailure(_ error: Error) {
    cmuxSettingsLog.error("Failed to write Settings edit to cmux.json: \(String(describing: error), privacy: .public)")
}

// Snapshots are immutable after capture and contain settings values copied
// before the background write-back reads files from disk.
struct ResolvedSettingsSnapshot: @unchecked Sendable {
    var path: String?
    var shortcuts: [KeyboardShortcutSettings.Action: StoredShortcut] = [:]
    var managedUserDefaults: [String: ManagedSettingsValue] = [:]
    var managedUserDefaultSources: [String: ManagedUserDefaultSource] = [:]
    var editableUserDefaults: [String: ManagedSettingsValue] = [:]
    var editableUserDefaultSources: [String: ManagedUserDefaultSource] = [:]
    var managedCustomSettings = ManagedCustomSettings()
    var managedCustomSettingSources: [String: ManagedCustomSettingSource] = [:]

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
            managedUserDefaultSources[key] = fallback.managedUserDefaultSources[key]
        }
        for (key, value) in fallback.editableUserDefaults where editableUserDefaults[key] == nil {
            editableUserDefaults[key] = value
            editableUserDefaultSources[key] = fallback.editableUserDefaultSources[key]
        }
        for (key, source) in fallback.editableUserDefaultSources where editableUserDefaultSources[key] == nil {
            editableUserDefaultSources[key] = source
        }
        if managedCustomSettings.socketPassword == nil,
           fallback.managedCustomSettings.socketPassword != nil {
            managedCustomSettingSources[CmuxSettingsFileStore.socketPasswordWriteBackIdentifier] =
                fallback.managedCustomSettingSources[CmuxSettingsFileStore.socketPasswordWriteBackIdentifier]
        }
        managedCustomSettings.fillMissingSettings(from: fallback.managedCustomSettings)
    }

    mutating func assignWriteBackSources(
        _ targets: [String: ManagedSettingsWriteBackTarget],
        sourcePath: String
    ) {
        for defaultsKey in managedUserDefaults.keys {
            guard let target = targets[defaultsKey] else { continue }
            managedUserDefaultSources[defaultsKey] = ManagedUserDefaultSource(
                sourcePath: sourcePath,
                jsonPath: target.jsonPath,
                valueKind: target.valueKind,
                writeBack: target.writeBack
            )
        }
    }

    mutating func assignEditableWriteBackSources(
        _ targets: [String: ManagedSettingsWriteBackTarget],
        sourcePath: String,
        captureStoredValues: Bool = true
    ) {
        for (defaultsKey, target) in targets {
            let source = ManagedUserDefaultSource(
                sourcePath: sourcePath,
                jsonPath: target.jsonPath,
                valueKind: target.valueKind,
                writeBack: target.writeBack
            )
            editableUserDefaultSources[defaultsKey] = managedUserDefaultSources[defaultsKey] ?? source
            if let managedValue = managedUserDefaults[defaultsKey] {
                editableUserDefaults[defaultsKey] = managedValue
            } else if captureStoredValues,
                      editableUserDefaults[defaultsKey] == nil,
                      let storedValue = target.valueKind.currentStoredValue(defaultsKey: defaultsKey) {
                editableUserDefaults[defaultsKey] = storedValue
            }
        }
    }
}

struct ManagedSettingsWriteBackTarget: Equatable {
    var jsonPath: String
    var valueKind: ManagedSettingsValueKind
    var writeBack: ManagedSettingsWriteBack = .storedValue
}

extension ManagedSettingsWriteBackTarget {
    static func bool(
        _ jsonPath: String,
        writeBack: ManagedSettingsWriteBack = .storedValue
    ) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .bool, writeBack: writeBack)
    }

    static func int(_ jsonPath: String) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .int)
    }

    static func double(_ jsonPath: String) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .double)
    }

    static func string(
        _ jsonPath: String,
        writeBack: ManagedSettingsWriteBack = .storedValue
    ) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .string, writeBack: writeBack)
    }

    static func nullableString(_ jsonPath: String) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .nullableString)
    }

    static func stringDictionary(_ jsonPath: String) -> ManagedSettingsWriteBackTarget {
        ManagedSettingsWriteBackTarget(jsonPath: jsonPath, valueKind: .stringDictionary)
    }
}

struct ManagedUserDefaultSource: Equatable {
    var sourcePath: String
    var jsonPath: String
    var valueKind: ManagedSettingsValueKind
    var writeBack: ManagedSettingsWriteBack
}

struct ManagedCustomSettingSource: Equatable {
    var sourcePath: String
    var jsonPath: String
}

enum ManagedSettingsWriteBack: Equatable {
    case storedValue
    case invertedBool
    case minimalPresentationMode
    case sidebarBranchLayout
    case newlineSeparatedStringArray

    func jsonValue(defaultsKey: String, currentValue: ManagedSettingsValue) -> Any? {
        switch (self, currentValue) {
        case (.storedValue, .bool(let value)):
            return value
        case (.storedValue, .int(let value)):
            return value
        case (.storedValue, .double(let value)):
            return value
        case (.storedValue, .string(let value)):
            return value
        case (.storedValue, .nullableString(let value)):
            return value ?? NSNull()
        case (.storedValue, .stringArray(let value)):
            return value
        case (.storedValue, .stringDictionary(let value)):
            return value
        case (.invertedBool, .bool(let value)):
            return !value
        case (.minimalPresentationMode, .string(let value)):
            return value == WorkspacePresentationModeSettings.Mode.minimal.rawValue
        case (.sidebarBranchLayout, .bool(let value)):
            return value ? "vertical" : "inline"
        case (.newlineSeparatedStringArray, .string(let value)):
            return value
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            cmuxSettingsLog.error(
                "Cannot write \(defaultsKey, privacy: .public) from \(String(describing: currentValue), privacy: .private) back to cmux.json"
            )
            return nil
        }
    }
}

enum ManagedStringOverride: Equatable {
    case set(String)
    case clear
}

enum ManagedSettingsValueKind: Equatable {
    case bool
    case int
    case double
    case string
    case nullableString
    case stringArray
    case stringDictionary

    func currentStoredValue(defaultsKey: String, defaults: UserDefaults = .standard) -> ManagedSettingsValue? {
        if defaultsKey == WorkspaceTabColorSettings.paletteKey,
           self == .stringDictionary,
           WorkspaceTabColorSettings.backupPaletteMap(defaults: defaults) != nil {
            return .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults))
        }

        guard defaults.object(forKey: defaultsKey) != nil else { return nil }

        switch self {
        case .bool:
            return .bool(defaults.bool(forKey: defaultsKey))
        case .int:
            return .int(defaults.integer(forKey: defaultsKey))
        case .double:
            return .double(defaults.double(forKey: defaultsKey))
        case .string:
            return .string(defaults.string(forKey: defaultsKey) ?? "")
        case .nullableString:
            return .nullableString(defaults.string(forKey: defaultsKey))
        case .stringArray:
            return .stringArray(defaults.array(forKey: defaultsKey) as? [String] ?? [])
        case .stringDictionary:
            return .stringDictionary(defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
        }
    }
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

enum ManagedSettingsValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case nullableString(String?)
    case stringArray([String])
    case stringDictionary([String: String])

    func currentValue(defaultsKey: String, defaults: UserDefaults = .standard) -> ManagedSettingsValue {
        if defaultsKey == WorkspaceTabColorSettings.paletteKey,
           case .stringDictionary = self {
            return .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults))
        }

        switch self {
        case .bool:
            return .bool(defaults.bool(forKey: defaultsKey))
        case .int:
            return .int(defaults.integer(forKey: defaultsKey))
        case .double:
            return .double(defaults.double(forKey: defaultsKey))
        case .string:
            return .string(defaults.string(forKey: defaultsKey) ?? "")
        case .nullableString:
            return .nullableString(defaults.string(forKey: defaultsKey))
        case .stringArray:
            return .stringArray(defaults.array(forKey: defaultsKey) as? [String] ?? [])
        case .stringDictionary:
            return .stringDictionary(defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:])
        }
    }
}

enum CmuxSettingsJSONWriter {
    static func write(
        _ changes: [(jsonPath: String, value: Any)],
        to path: String,
        fileManager: FileManager
    ) throws {
        let fileURL = URL(fileURLWithPath: path)
        let data = fileManager.contents(atPath: path) ?? Data("{}".utf8)
        let securityAttributes = existingSecurityAttributes(at: path, fileManager: fileManager)
        let sourceText = try JSONCParser.sourceText(from: data)
        let replacements = try changes.map { change in
            (
                jsonPath: change.jsonPath,
                literal: try JSONCValueEditor.literal(for: change.value)
            )
        }
        let editedText = try JSONCValueEditor.settingValues(replacements, in: sourceText.text)
        guard let output = editedText.data(using: sourceText.encoding) else {
            throw JSONCValueEditor.EditError.malformedJSONC("failed to encode edited settings file")
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try output.write(to: fileURL, options: [.atomic])
        try restoreSecurityAttributes(securityAttributes, to: path, fileManager: fileManager)
    }

    private static func existingSecurityAttributes(
        at path: String,
        fileManager: FileManager
    ) -> [FileAttributeKey: Any]? {
        guard let existing = try? fileManager.attributesOfItem(atPath: path) else {
            return nil
        }
        let keys: [FileAttributeKey] = [.posixPermissions, .ownerAccountID, .groupOwnerAccountID]
        let attributes = keys.reduce(into: [FileAttributeKey: Any]()) { result, key in
            if let value = existing[key] {
                result[key] = value
            }
        }
        return attributes.isEmpty ? nil : attributes
    }

    private static func restoreSecurityAttributes(
        _ attributes: [FileAttributeKey: Any]?,
        to path: String,
        fileManager: FileManager
    ) throws {
        guard let attributes else {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return
        }
        var ownershipAttributes: [FileAttributeKey: Any] = [:]
        ownershipAttributes[.ownerAccountID] = attributes[.ownerAccountID]
        ownershipAttributes[.groupOwnerAccountID] = attributes[.groupOwnerAccountID]
        if !ownershipAttributes.isEmpty {
            try? fileManager.setAttributes(ownershipAttributes, ofItemAtPath: path)
        }
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }
}

// Write-back plans are immutable after creation; values are JSON scalars or
// arrays collected before the plan crosses to background file I/O.
struct ManagedSettingsWriteBackPlan: @unchecked Sendable {
    private let changesBySourcePath: [String: [String: Any]]

    init(changesBySourcePath: [String: [String: Any]]) {
        self.changesBySourcePath = changesBySourcePath
    }

    func write(fileManager: FileManager) throws {
        for sourcePath in changesBySourcePath.keys.sorted() {
            let changesByPath = changesBySourcePath[sourcePath] ?? [:]
            let changes = changesByPath.keys.sorted().map { jsonPath in
                (jsonPath: jsonPath, value: changesByPath[jsonPath]!)
            }
            try CmuxSettingsJSONWriter.write(changes, to: sourcePath, fileManager: fileManager)
        }
    }
}

struct ManagedSettingsFileIO: @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager) {
        self.fileManager = fileManager
    }

    func write(_ plan: ManagedSettingsWriteBackPlan) throws {
        try plan.write(fileManager: fileManager)
    }
}

actor ManagedSettingsWriteBackCoordinator {
    private var generation: UInt64 = 0
    private var writeTail: Task<Void, Never>?

    func invalidate() {
        generation &+= 1
    }

    func schedule(
        work: @escaping @Sendable () async throws -> Void
    ) async -> Result<Void, Error>? {
        generation &+= 1
        let currentGeneration = generation
        let previousWrite = writeTail
        let task = Task.detached(priority: .utility) { () -> Result<Void, Error>? in
            await previousWrite?.value
            guard await self.isCurrent(currentGeneration) else { return nil }
            do {
                try await work()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        writeTail = Task { _ = await task.value }
        guard let result = await task.value else { return nil }
        guard currentGeneration == generation else { return nil }
        return result
    }

    private func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

enum CmuxSettingsManagedEditWriter {
    static func makeWriteBackPlan(snapshot: ResolvedSettingsSnapshot) -> ManagedSettingsWriteBackPlan? {
        var changesBySourcePath: [String: [String: Any]] = [:]
        collectUserDefaultEdits(snapshot: snapshot, changesBySourcePath: &changesBySourcePath)
        collectNewUserDefaultEdits(snapshot: snapshot, changesBySourcePath: &changesBySourcePath)
        collectCustomSettingEdits(snapshot: snapshot, changesBySourcePath: &changesBySourcePath)
        guard !changesBySourcePath.isEmpty else { return nil }
        return ManagedSettingsWriteBackPlan(changesBySourcePath: changesBySourcePath)
    }

    private static func collectUserDefaultEdits(
        snapshot: ResolvedSettingsSnapshot,
        changesBySourcePath: inout [String: [String: Any]]
    ) {
        for (defaultsKey, managedValue) in snapshot.managedUserDefaults {
            let currentValue = managedValue.currentValue(defaultsKey: defaultsKey)
            guard currentValue != managedValue,
                  let source = snapshot.managedUserDefaultSources[defaultsKey],
                  let jsonValue = source.writeBack.jsonValue(
                    defaultsKey: defaultsKey,
                    currentValue: currentValue
                  ) else {
                continue
            }
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = jsonValue
        }
    }

    private static func collectNewUserDefaultEdits(
        snapshot: ResolvedSettingsSnapshot,
        changesBySourcePath: inout [String: [String: Any]]
    ) {
        for (defaultsKey, source) in snapshot.editableUserDefaultSources where snapshot.managedUserDefaults[defaultsKey] == nil {
            guard let currentValue = source.valueKind.currentStoredValue(defaultsKey: defaultsKey),
                  snapshot.editableUserDefaults[defaultsKey] != currentValue,
                  let jsonValue = source.writeBack.jsonValue(
                    defaultsKey: defaultsKey,
                    currentValue: currentValue
                  ) else {
                continue
            }
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = jsonValue
        }
    }

    private static func collectCustomSettingEdits(
        snapshot: ResolvedSettingsSnapshot,
        changesBySourcePath: inout [String: [String: Any]]
    ) {
        guard let managedSocketPassword = snapshot.managedCustomSettings.socketPassword,
              let source = snapshot.managedCustomSettingSources[CmuxSettingsFileStore.socketPasswordWriteBackIdentifier]
        else { return }

        let currentSocketPassword: String?
        do {
            currentSocketPassword = try SocketControlPasswordStore.loadPassword()
        } catch {
            cmuxSettingsLog.error("Failed to read socket password before cmux.json write-back: \(String(describing: error), privacy: .public)")
            return
        }
        let didChange: Bool = {
            switch managedSocketPassword {
            case .set(let value):
                return currentSocketPassword != value
            case .clear:
                return currentSocketPassword != nil
            }
        }()
        guard didChange else { return }
        if let currentSocketPassword {
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = currentSocketPassword
        } else {
            changesBySourcePath[source.sourcePath, default: [:]][source.jsonPath] = NSNull()
        }
    }
}
