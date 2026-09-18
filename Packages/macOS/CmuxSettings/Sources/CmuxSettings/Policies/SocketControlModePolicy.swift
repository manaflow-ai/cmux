public import Foundation

/// Resolves the MDM-managed access mode for the local automation socket.
///
/// The local automation socket is the one surface a user can widen on their
/// own: the Settings picker, a `cmux.json` import, and the
/// `CMUX_SOCKET_ENABLE` / `CMUX_SOCKET_MODE` environment variables all reach
/// it. An administrator pins it with the forced
/// ``ManagedDevicePolicyKey/socketControlMode`` key, and this type answers the
/// two questions every caller needs:
///
/// - Is the mode managed right now, so every writer must lock?
/// - Which mode does the profile force?
///
/// Only ``forcibleModes`` may be forced. Every other forced value — a mode
/// that would widen access, an unknown string, or a value of the wrong type —
/// still counts as managed, but resolves to ``fallbackMode``. A profile can
/// therefore lock the socket down but never open it, which keeps a malformed
/// payload fail-closed instead of permissive.
///
/// ```swift
/// let policy = SocketControlModePolicy()
/// let mode = SocketControlSettings.effectiveMode(
///     userMode: userMode,
///     managedMode: policy.mode
/// )
/// ```
public struct SocketControlModePolicy: Equatable, Sendable {
    /// The administrator-facing forced preference key in the policy domain.
    public static let managedDefaultsKey = ManagedDevicePolicyKey.socketControlMode.rawValue

    /// The regular user preference key used by Settings and `cmux.json`. An
    /// administrator may force this key directly instead of the dedicated one.
    public static let userDefaultsKey = SocketControlSettings.appStorageKey

    /// The modes an administrator may force. Both restrict the socket: `off`
    /// closes it entirely, `cmuxOnly` admits only processes started inside
    /// cmux. `automation` and `allowAll` widen access, and `password` admits
    /// any local process holding a credential that `CMUX_SOCKET_PASSWORD` can
    /// supply, so none of the three is forcible.
    public static let forcibleModes: [SocketControlMode] = [.off, .cmuxOnly]

    /// The mode a managed but unusable forced value resolves to.
    public static let fallbackMode: SocketControlMode = .cmuxOnly

    /// Where the effective mode came from.
    public enum Source: Equatable, Sendable {
        /// No profile forces the mode; the user's own setting applies.
        case unmanaged
        /// A configuration profile forces the mode.
        case managed
    }

    /// The effective source.
    public let source: Source

    /// The forced mode, or `nil` when no profile manages the socket.
    ///
    /// Callers pass this straight to
    /// ``SocketControlSettings/effectiveMode(userMode:environment:managedMode:)``.
    public let mode: SocketControlMode?

    /// Whether an administrator supplied a forced value, including one that
    /// was empty, permissive, or malformed.
    public var isManaged: Bool { source == .managed }

    /// Resolves the policy from the supplied preference suite.
    ///
    /// - Parameters:
    ///   - defaults: The app/channel preference suite.
    ///   - managedDevicePolicy: An optional injected resolver for tests or a
    ///     composition root that already owns one.
    public init(
        defaults: UserDefaults = .standard,
        managedDevicePolicy: ManagedDevicePolicy? = nil
    ) {
        let resolver = managedDevicePolicy ?? ManagedDevicePolicy(defaults: defaults)
        self.init(forcedRawValue: resolver.forcedSocketControlModeObject(
            userDefaultsKey: Self.userDefaultsKey
        ))
    }

    /// Creates a policy from an explicit forced value, primarily for
    /// deterministic tests.
    ///
    /// - Parameter forcedRawValue: The object a profile forces, or `nil` when
    ///   no profile manages the socket.
    public init(forcedRawValue: Any?) {
        guard let forcedRawValue else {
            self.source = .unmanaged
            self.mode = nil
            return
        }
        self.source = .managed
        self.mode = Self.forcibleMode(from: forcedRawValue) ?? Self.fallbackMode
    }

    /// Maps a forced object to a forcible mode, or `nil` when the value names
    /// no mode or names one an administrator may not force.
    private static func forcibleMode(from rawValue: Any) -> SocketControlMode? {
        guard let rawString = rawValue as? String,
              let parsed = SocketControlSettings.parseMode(rawString),
              forcibleModes.contains(parsed) else {
            return nil
        }
        return parsed
    }
}

public extension ManagedDevicePolicy {
    /// Whether the automation socket's access mode is locked by MDM.
    ///
    /// The dedicated policy key and the user-level key are checked across the
    /// app and release domains, so a channel build honors a release-domain
    /// profile.
    func isSocketControlModeLocked(userDefaultsKey: String) -> Bool {
        forcedSocketControlModeObject(userDefaultsKey: userDefaultsKey) != nil
    }

    /// Returns the forced value that owns the effective socket access mode.
    /// The dedicated policy key wins over a directly forced user key.
    func forcedSocketControlModeObject(userDefaultsKey: String) -> Any? {
        forcedObject(forUserDefaultsKey: ManagedDevicePolicyKey.socketControlMode.rawValue)
            ?? forcedObject(forUserDefaultsKey: userDefaultsKey)
    }
}
