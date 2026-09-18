public import Foundation

/// The automation socket's effective access state, as `cmux socket status`
/// reports it.
///
/// An administrator runs that command to confirm a configuration profile
/// landed on a host, so the report answers three questions at once: which mode
/// the listener actually runs, which mode the user asked for, and which of the
/// two is in force. It resolves the same way the listener does — through
/// ``SocketControlSettings/effectiveMode(userMode:environment:managedMode:)`` —
/// so the two can never disagree.
///
/// Reading it needs neither a running app nor a live socket, which matters
/// because `off` and a failed launch both leave nothing to connect to.
public struct SocketControlStatusReport: Equatable, Sendable {
    /// The user's own configured mode, before any policy or environment
    /// override. Reported alongside ``effectiveMode`` so an administrator can
    /// see what the policy overrode.
    public let configuredMode: SocketControlMode

    /// The mode the listener runs.
    public let effectiveMode: SocketControlMode

    /// Whether a configuration profile owns the mode.
    public let isManaged: Bool

    /// The preference domain the report was read from.
    public let domain: String

    /// The resolved control-socket path.
    public let socketPath: String

    /// Builds a report from the user's mode and the resolved policy.
    ///
    /// - Parameters:
    ///   - configuredMode: The user's own configured mode.
    ///   - policy: The resolved managed policy.
    ///   - environment: The process environment, consulted only when no
    ///     profile manages the mode.
    ///   - domain: The preference domain the values were read from.
    ///   - socketPath: The resolved control-socket path.
    public init(
        configuredMode: SocketControlMode,
        policy: SocketControlModePolicy,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        domain: String,
        socketPath: String
    ) {
        self.configuredMode = configuredMode
        self.effectiveMode = SocketControlSettings.effectiveMode(
            userMode: configuredMode,
            environment: environment,
            managedMode: policy.mode
        )
        self.isManaged = policy.isManaged
        self.domain = domain
        self.socketPath = socketPath
    }

    /// The one-line human summary: the effective mode, marked when a profile
    /// owns it. Deliberately not localized — it is a machine-readable token a
    /// fleet check greps for, like `cmux browser status`'s own output.
    public var summary: String {
        isManaged ? "\(effectiveMode.rawValue) (managed)" : effectiveMode.rawValue
    }

    /// The `--json` payload.
    public var jsonObject: [String: Any] {
        [
            "mode": effectiveMode.rawValue,
            "configured_mode": configuredMode.rawValue,
            "managed": isManaged,
            "source": isManaged ? "managed" : "user",
            "domain": domain,
            "key": SocketControlModePolicy.managedDefaultsKey,
            "socket_path": socketPath,
        ]
    }
}
