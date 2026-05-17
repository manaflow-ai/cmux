import Foundation
import os

nonisolated private let cmuxSettingsLog = Logger(subsystem: "com.cmuxterm.app", category: "SettingsFile")

func logManagedSettingsWriteBackFailure(_ error: Error) {
    cmuxSettingsLog.error("Failed to write Settings edit to cmux.json: \(String(describing: error), privacy: .private)")
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
        switch self {
        case .bool:
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
            return .bool(defaults.bool(forKey: defaultsKey))
        case .int:
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
            return .int(defaults.integer(forKey: defaultsKey))
        case .double:
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
            return .double(defaults.double(forKey: defaultsKey))
        case .string:
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
            return .string(defaults.string(forKey: defaultsKey) ?? "")
        case .nullableString:
            return .nullableString(defaults.string(forKey: defaultsKey))
        case .stringArray:
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
            return .stringArray(defaults.array(forKey: defaultsKey) as? [String] ?? [])
        case .stringDictionary:
            if defaultsKey == WorkspaceTabColorSettings.paletteKey,
               WorkspaceTabColorSettings.backupPaletteMap(defaults: defaults) != nil {
                return .stringDictionary(WorkspaceTabColorSettings.resolvedPaletteMap(defaults: defaults))
            }
            guard defaults.object(forKey: defaultsKey) != nil else { return nil }
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

enum ManagedSettingsValue: Codable, Equatable {
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
