import Foundation

/// Identifies the owner of the effective socket-control value.
public enum SocketControlPolicySource: String, Equatable, Sendable {
    /// A configuration profile forces the app's own preference domain.
    case managedAppDomain = "managed_app_domain"
    /// A tagged/channel build inherits a profile from the release domain.
    case managedReleaseDomain = "managed_release_domain"
    /// The value came from the process environment.
    case environment = "environment"
    /// The value came from the user's settings/defaults.
    case userDefaults = "user_defaults"
}

/// The single resolved socket-control decision shared by startup, reload,
/// Settings, policy enforcement, and compliance reporting.
public struct SocketControlPolicyResolution: Equatable, Sendable {
    /// The access mode the listener must enforce.
    public let mode: SocketControlMode
    /// The user/configured mode before environment or managed overrides.
    public let configuredMode: SocketControlMode
    /// The source that owns `mode`.
    public let source: SocketControlPolicySource
    /// `valid` for a valid forced profile value, `invalid` for a forced value
    /// of the wrong type or an unsupported/broader string, and `nil` when the
    /// socket mode is unmanaged.
    public let forcedValueStatus: String?

    /// Creates a resolved policy snapshot.
    public init(
        mode: SocketControlMode,
        configuredMode: SocketControlMode,
        source: SocketControlPolicySource,
        forcedValueStatus: String? = nil
    ) {
        self.mode = mode
        self.configuredMode = configuredMode
        self.source = source
        self.forcedValueStatus = forcedValueStatus
    }

    /// Whether a configuration profile owns the effective mode.
    public var isManaged: Bool {
        switch source {
        case .managedAppDomain, .managedReleaseDomain:
            return true
        case .environment, .userDefaults:
            return false
        }
    }

    /// The machine-readable managed source, or `nil` for an unmanaged value.
    public var managedSource: String? {
        isManaged ? source.rawValue : nil
    }
}

/// Resolves the automation socket mode with one authoritative precedence
/// order: a genuinely forced MDM value wins first; otherwise environment
/// overrides win over the user's setting, preserving existing behavior.
///
/// Only `cmuxOnly` and `off` are valid forced values. A malformed forced value
/// is still managed and fails closed to `off`; removing the profile restores
/// the unmanaged user/environment decision.
public struct SocketControlPolicyResolver {
    // UserDefaults is documented thread-safe but is not annotated Sendable by
    // the SDK. The handle is immutable; all mutable state remains in the
    // UserDefaults implementation and ManagedDevicePolicy probe.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let environment: [String: String]
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
        if let forcedSource = managedPolicy.forcedValueSource(forUserDefaultsKey: policyKey) {
            let forcedObject = managedPolicy.forcedObject(forUserDefaultsKey: policyKey)
            if let forcedMode = restrictiveForcedMode(forcedObject) {
                return SocketControlPolicyResolution(
                    mode: forcedMode,
                    configuredMode: configuredMode,
                    source: source(forcedSource),
                    forcedValueStatus: "valid"
                )
            }
            return SocketControlPolicyResolution(
                mode: .off,
                configuredMode: configuredMode,
                source: source(forcedSource),
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
        let raw = defaults.string(forKey: SocketControlSettings.appStorageKey)
            ?? SocketControlSettings.defaultMode.rawValue
        return SocketControlSettings.migrateMode(raw)
    }

    private func source(_ forcedSource: ManagedDevicePolicy.ValueSource) -> SocketControlPolicySource {
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
