extension DaemonConnection {
    /// Captures the inventory watch manager belonging to the current control transport.
    ///
    /// Repeated captures on this transport return the same manager. After a
    /// reconnect callers must revalidate route admission and capture again;
    /// the old manager never redirects cleanup to the replacement connection.
    /// - Parameter expectedMachineID: The canonical owner admitted by the route registry.
    /// - Returns: This ready transport's shared subscription manager.
    /// - Throws: Missing capability, no ready connection, or a mismatched owner.
    public func agentInventoryWatch(expectedMachineID: ResourceID) throws -> AgentInventoryWatch {
        guard let ready else { throw DaemonError.notConnected }
        try MachineAgentInventoryWatchRequest.requireServed(by: ready.identity)
        guard ready.identity.machineResourceID == expectedMachineID, let watch = ready.inventoryWatch else {
            throw DaemonError.malformedResponse("Inventory watch owner did not match the admitted machine")
        }
        return watch
    }
}
