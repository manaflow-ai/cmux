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
}
