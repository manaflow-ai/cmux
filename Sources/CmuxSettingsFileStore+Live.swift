import CmuxSettings
import Foundation

extension CmuxSettingsFileStore {
    /// Returns the user-selected socket mode before process environment overrides.
    static func configuredSocketMode(defaults: UserDefaults = .standard) -> SocketControlMode {
        let raw = defaults.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        return SocketControlSettings.migrateMode(raw)
    }

    /// Returns the effective socket access policy represented by live defaults.
    static func liveSocketAccessMode(defaults: UserDefaults = .standard) -> SocketControlMode {
        SocketControlSettings.effectiveMode(userMode: configuredSocketMode(defaults: defaults))
    }

    /// Preserves restrictive policies; broader invalid policies fall back to `cmuxOnly`.
    static func failClosedSocketMode(defaults: UserDefaults = .standard) -> SocketControlMode {
        let configuredMode = configuredSocketMode(defaults: defaults)
        switch configuredMode {
        case .off, .cmuxOnly, .password:
            return configuredMode
        case .automation, .allowAll:
            return .cmuxOnly
        }
    }

    /// Makes a newly bootstrapped primary file the durable owner of the resolved socket policy.
    static func materializeBootstrapSocketPolicy(
        in template: Data,
        imported: ManagedSettingsValue?
    ) -> Data {
        guard let imported else { return template }
        let resolved = socketModeAfterMissingPrimary(
            prior: imported,
            fallback: socketModeManagedValue(in: template)
        )
        guard case .string(let rawMode) = resolved else { return template }
        let source = (try? JSONCParser.source(data: template).text) ?? defaultTemplate()
        let encodedMode = "\"\(rawMode)\""
        if let updated = JSONCObjectEditor.setNestedObjectProperty(
            parentKey: "automation",
            childKey: "socketControlMode",
            childValueJSON: encodedMode,
            in: source
        ) {
            return Data(updated.utf8)
        }
        return Data(minimalBootstrapSettingsSource(socketMode: rawMode).utf8)
    }

    private static func socketModeManagedValue(in data: Data) -> ManagedSettingsValue? {
        guard let sanitized = try? JSONCParser.preprocess(data: data),
              let root = try? JSONSerialization.jsonObject(with: sanitized) as? [String: Any],
              let automation = root["automation"] as? [String: Any],
              let rawMode = automation["socketControlMode"] as? String else { return nil }
        return .string(SocketControlSettings.migrateMode(rawMode).rawValue)
    }

    private static func minimalBootstrapSettingsSource(socketMode: String) -> String {
        """
        {
          "$schema": "\(schemaURLString)",
          "schemaVersion": \(currentSchemaVersion),
          "automation": { "socketControlMode": "\(socketMode)" }
        }

        """
    }

    /// Resolves a missing primary without broadening the last live managed policy.
    static func socketModeAfterMissingPrimary(
        prior: ManagedSettingsValue?,
        fallback: ManagedSettingsValue?,
        defaults: UserDefaults = .standard
    ) -> ManagedSettingsValue {
        guard let priorMode = socketMode(from: prior) else {
            return fallback ?? .string(failClosedSocketMode(defaults: defaults).rawValue)
        }
        guard let fallbackMode = socketMode(from: fallback) else { return .string(priorMode.rawValue) }
        let resolvedMode = restrictiveFallbackMode(current: priorMode, candidate: fallbackMode)
        return .string(resolvedMode.rawValue)
    }

    private static func socketMode(from value: ManagedSettingsValue?) -> SocketControlMode? {
        guard case .string(let raw) = value else { return nil }
        return SocketControlSettings.migrateMode(raw)
    }

    private static func restrictiveFallbackMode(
        current: SocketControlMode,
        candidate: SocketControlMode
    ) -> SocketControlMode {
        if candidate == current || candidate == .off { return candidate }
        if current == .allowAll { return candidate }
        // `cmuxOnly` and `password` are incomparable, so only transition from a broader mode.
        if current == .automation, candidate == .cmuxOnly || candidate == .password { return candidate }
        return current
    }

    /// Creates the process store wired to the host's shared reload coordinator.
    static var appLive: CmuxSettingsFileStore {
        CmuxSettingsFileStore(
            onWatchedFileReload: { source in
                AppDelegate.shared?.reconcileSocketListenerConfiguration(source: source)
            }
        )
    }
}
