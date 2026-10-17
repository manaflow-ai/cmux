public import CmuxNextDaemon

/// An existing, policy-admitted ready route supplied by the machine registry.
public nonisolated struct AgentInventoryWatchRoute: Equatable, Sendable {
    /// Canonical owner of the ready handshake.
    public let machine: ResourceID
    /// Existing connection; capturing this route never connects or starts a machine.
    public let connection: DaemonConnection
    /// The registry's connection epoch, changed even for a same-object reconnect.
    public let epoch: Int
    /// The existing store's stamped fanout; no second connection stream is consumed.
    public let events: DaemonSideEvents
    /// The ready transport actually observed by the registry, absent before stamped admission.
    public let controlStamp: DaemonControlStamp?

    /// Captures an already admitted ready route.
    /// - Parameters:
    ///   - machine: Canonical ready owner, never a UI alias.
    ///   - connection: Existing registry-owned connection.
    ///   - epoch: Current store connection epoch.
    ///   - events: That connection's store side-event fanout.
    @MainActor public init(machine: ResourceID, connection: DaemonConnection, epoch: Int, events: DaemonSideEvents) {
        self.machine = machine; self.connection = connection; self.epoch = epoch; self.events = events
        controlStamp = events.controlStamp
    }

    /// Compares owner, exact carrier, route epoch and side-event owner.
    /// - Parameters:
    ///   - lhs: First admitted route.
    ///   - rhs: Second admitted route.
    /// - Returns: Whether both snapshots represent the same admission.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machine == rhs.machine && lhs.connection === rhs.connection && lhs.epoch == rhs.epoch
            && lhs.events === rhs.events && lhs.controlStamp == rhs.controlStamp
    }
}
