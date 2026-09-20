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

