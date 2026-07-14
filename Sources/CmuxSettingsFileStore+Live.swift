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

    /// Returns the persisted managed socket mode only when the primary is absent at cold start.
    static func coldStartSocketMode(
        _ primaryPath: String,
        fileManager: FileManager,
        imported: [String: ManagedSettingsValue]
    ) -> ManagedSettingsValue? {
        guard !fileManager.fileExists(atPath: primaryPath) else { return nil }
        return imported[SocketControlSettings.appStorageKey]
    }

    /// Reconciles a bootstrapped primary through the missing-primary restrictive precedence rule.
    static func preserveColdStartSocketMode(
        _ coldStartSocketMode: ManagedSettingsValue?,
        in snapshot: inout ResolvedSettingsSnapshot
    ) {
        guard let coldStartSocketMode else { return }
        snapshot.managedUserDefaults[SocketControlSettings.appStorageKey] = socketModeAfterMissingPrimary(
            prior: coldStartSocketMode,
            fallback: snapshot.managedUserDefaults[SocketControlSettings.appStorageKey]
        )
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
