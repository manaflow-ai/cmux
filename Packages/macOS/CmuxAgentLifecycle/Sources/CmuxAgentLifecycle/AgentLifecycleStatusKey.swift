/// A sidebar key participating in agent lifecycle reconciliation.
public nonisolated struct AgentLifecycleStatusKey: RawRepresentable, Codable, Hashable, Sendable {
    /// The underlying sidebar key.
    public let rawValue: String

    /// Creates a status-key value.
    ///
    /// - Parameter rawValue: The exact sidebar key.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The reserved root key for manual workspace-loading activity.
    public static let manualKey = "manual"

    /// Every status key owned by a built-in integration.
    public static let allowedStatusKeys = Set(
        BuiltInAgentIntegration.allCases.map(\.statusKey)
    )

    /// Whether this key belongs to the reserved manual-loading namespace.
    public var isManual: Bool {
        rawValue == Self.manualKey
            || rawValue.hasPrefix("\(Self.manualKey):")
    }

    /// Whether this key is owned by a built-in integration.
    public var isAllowed: Bool {
        Self.allowedStatusKeys.contains(rawValue)
    }

    /// The built-in status key at the root of this key's session namespace.
    ///
    /// Session-scoped PID keys use `<status-key>.<session-id>` while lifecycle
    /// state remains rooted at `<status-key>`.
    public var builtInStatusKey: String? {
        let candidate = rawValue.split(
            separator: ".",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? rawValue
        return Self.allowedStatusKeys.contains(candidate) ? candidate : nil
    }

    /// Whether this key is a built-in status key or one of its session keys.
    public var isBuiltInNamespace: Bool {
        builtInStatusKey != nil
    }
}
