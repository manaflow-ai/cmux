public import CmuxNextDaemon

/// One immutable view of an existing machine route, supplied by the app's registry.
public nonisolated struct AgentInventoryRoute: Sendable {
    /// The public owner ID, nil until an identifying handshake has completed.
    public let machineID: ResourceID?
    /// The existing carrier; nil while disconnected. No read creates a connection.
    public let reader: (any AgentInventoryReader)?
    /// Whether policy currently admits this route.
    public let allowed: Bool
    /// The explicit default route when the caller omits a machine, normally local.
    public let isDefault: Bool

    /// Captures a route without deriving an owner ID or granting access.
    /// - Parameters:
    ///   - machineID: The registry's last public owner identity, if known.
    ///   - reader: The registry's existing connection, if any.
    ///   - allowed: The registry's current policy decision.
    ///   - isDefault: Whether this route is the caller's explicit default.
    public init(machineID: ResourceID?, reader: (any AgentInventoryReader)?, allowed: Bool, isDefault: Bool) {
        self.machineID = machineID
        self.reader = reader
        self.allowed = allowed
        self.isDefault = isDefault
    }
}
