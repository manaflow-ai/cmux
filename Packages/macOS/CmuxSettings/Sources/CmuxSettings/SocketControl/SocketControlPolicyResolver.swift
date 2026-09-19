import Foundation

/// Resolves the automation socket mode with one authoritative precedence
/// order: a genuinely forced MDM value wins first; otherwise environment
/// overrides win over the user's setting, preserving existing behavior.
///
/// Only `cmuxOnly` and `off` are valid forced values. A malformed forced value
/// is still managed and fails closed to `off`; removing the profile restores
/// the unmanaged user/environment decision.
public struct SocketControlPolicyResolver: Sendable {
    // UserDefaults is documented thread-safe but is not annotated Sendable by
    // the SDK. The handle is immutable; all mutable state remains in the
    // UserDefaults implementation and ManagedDevicePolicy probe.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let environment: [String: String]
    private let bundleIdentifier: String?
    private let managedPolicy: ManagedDevicePolicy

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - defaults: The running app's user-preference suite.
    ///   - environment: Process environment used for legacy socket overrides.
    ///   - bundleIdentifier: Bundle identity used to inherit the release
    ///     payload domain for tagged/channel builds.
    ///   - managedPolicy: Optional injected policy resolver for deterministic
    ///     tests; production callers normally omit it.
    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        managedPolicy: ManagedDevicePolicy? = nil
    ) {
        self.defaults = defaults
        self.environment = environment
        self.bundleIdentifier = bundleIdentifier
        self.managedPolicy = managedPolicy ?? ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: ManagedDevicePolicy.defaultReleaseDomainDefaults(
                bundleIdentifier: bundleIdentifier
            )
        )
    }

    /// Resolves the effective mode and management metadata.
    public func resolve() -> SocketControlPolicyResolution {
        let configuredMode = configuredUserMode()
        let policyKey = ManagedDevicePolicyKey.socketControlMode.rawValue
        if let forced = managedPolicy.forcedValue(forUserDefaultsKey: policyKey) {
            if let forcedMode = restrictiveForcedMode(forced.object) {
                return SocketControlPolicyResolution(
                    mode: forcedMode,
                    configuredMode: configuredMode,
                    source: source(forced.source),
                    forcedValueStatus: "valid"
                )
            }
            return SocketControlPolicyResolution(
                mode: .off,
                configuredMode: configuredMode,
                source: source(forced.source),
                forcedValueStatus: "invalid"
            )
        }

        let effectiveMode = SocketControlSettings.effectiveMode(
            userMode: configuredMode,
            environment: environment
        )
        let hasEnvironmentOverride = SocketControlSettings.envOverrideEnabled(environment: environment) != nil
            || SocketControlSettings.envOverrideMode(environment: environment) != nil
        return SocketControlPolicyResolution(
            mode: effectiveMode,
            configuredMode: configuredMode,
            source: hasEnvironmentOverride ? .environment : .userDefaults
        )
    }

    private func configuredUserMode() -> SocketControlMode {
        // A forced preference shadows ordinary UserDefaults reads. The
        // persistent application domain is the unforced user value, so CLI
        // compliance output can show what the user configured before MDM
        // enforcement instead of echoing the forced mode as both fields.
        let raw = unforcedUserValue() as? String
            ?? defaults.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        return SocketControlSettings.migrateMode(raw)
    }

    private func unforcedUserValue() -> Any? {
        guard let bundleIdentifier,
              let domain = defaults.persistentDomain(forName: bundleIdentifier) else {
            return nil
        }
        return domain[SocketControlSettings.appStorageKey]
    }

    private func source(_ forcedSource: ManagedDevicePolicyValueSource) -> SocketControlPolicySource {
        switch forcedSource {
        case .appDomain:
            return .managedAppDomain
        case .releaseDomain:
            return .managedReleaseDomain
        }
    }

    private func restrictiveForcedMode(_ object: Any?) -> SocketControlMode? {
        guard let raw = object as? String else { return nil }
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        switch normalized {
        case "cmuxonly":
            return .cmuxOnly
        case "off":
            return .off
        default:
            return nil
        }
    }
}
