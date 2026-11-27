public import Foundation

/// An admitted watch manager and the exact source stamp of its ready transport.
public nonisolated struct AgentInventoryWatchCarrier: Sendable {
    /// Shared manager for this machine on this control transport.
    public let watch: AgentInventoryWatch
    /// Source instance for targeted watch notices.
    public let sourceID: UUID
    /// Control serial for targeted watch notices.
    public let serial: UInt64

    /// Captures the manager and stamp atomically without opening a connection.
    /// - Parameters:
    ///   - connection: The existing ready owner connection.
    ///   - expectedMachineID: The registry's currently admitted canonical owner.
    /// - Throws: Missing capability, no ready connection or owner mismatch.
    public init(connection: isolated DaemonConnection, expectedMachineID: ResourceID) throws {
        watch = try connection.agentInventoryWatch(expectedMachineID: expectedMachineID)
        guard let ready = connection.ready else { throw DaemonError.notConnected }
        sourceID = connection.eventSourceID; serial = ready.serial
    }

    /// Matches the original notice stamp before interpreting its owner or lease.
    /// - Parameter envelope: A native notice with its original source.
    /// - Returns: Whether it belongs to this captured transport.
    public func matches(_ envelope: DaemonEventEnvelope) -> Bool {
        envelope.sourceID == sourceID && envelope.connectionSerial == serial
    }
}
