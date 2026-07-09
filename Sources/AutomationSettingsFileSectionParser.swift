import CmuxSettings
import Foundation

/// Stateless parser for the `automation` section of a cmux settings JSON root.
///
/// Projects the decoded `automation` object into a ``ResolvedSettingsSnapshot``:
/// the socket-control mode, socket password (set/clear), the boolean and string
/// automation toggles, the Kiro notification level, and the automation port
/// base/range. It reuses the `CmuxSettings` value shapes that own these settings
/// (``SocketControlSettings`` for mode migration/storage key,
/// ``KiroNotificationLevel`` for the notification level, and
/// ``IntegrationsCatalogSection`` for that level's defaults key) plus the
/// app-side ``AutomationSettings`` port keys, and the shared
/// ``SettingsFileProjectionEngine`` for the table-driven applies, JSON scalar
/// coercion, and invalid-setting logging. It holds no paths and touches no
/// filesystem; ``SettingsFileParser`` constructs it with its projection engine
/// and forwards the section once per source file.
struct AutomationSettingsFileSectionParser {
    private let projection: SettingsFileProjectionEngine

    init(projection: SettingsFileProjectionEngine) {
        self.projection = projection
    }

    func parse(
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
        projection.applyBooleanSettings(AutomationSettingsFileMapping.booleanSettings, from: section, sourcePath: sourcePath, into: &snapshot)
        projection.applyStringSettings(AutomationSettingsFileMapping.stringSettings, from: section, into: &snapshot)
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

    // The domain-agnostic projection engine (table-driven apply, invalid-setting
    // logging, JSON scalar coercion) lives in `CmuxSettings`. This parser holds the
    // same instance its owner (`SettingsFileParser`) holds and forwards the shared
    // `logInvalid`/`json*` helpers to it so the moved call sites stay unchanged.
    private func logInvalid(_ path: String, sourcePath: String) {
        projection.logInvalid(path, sourcePath: sourcePath)
    }

    private func jsonString(_ rawValue: Any?) -> String? {
        projection.jsonString(rawValue)
    }

    private func jsonInt(_ rawValue: Any?) -> Int? {
        projection.jsonInt(rawValue)
    }
}
