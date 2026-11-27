public import CmuxNextDaemon

extension DaemonConnection: AgentInventoryReader {
    /// Reads the selected machine's cache through the negotiated native owner check.
    /// - Parameter machine: The public machine ID selected by the caller.
    /// - Returns: Cached observations from exactly that owner.
    /// - Throws: Unsupported, mismatched, unavailable or cancelled reads, without fallback.
    public func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        try await request(MachineAgentInventoryRequest(expectedMachineID: machine), timeout: .seconds(15))
    }

    /// Refreshes only registry observations through this captured, negotiated owner.
    /// - Parameter machine: The canonical machine selected from the admitted routes.
    /// - Returns: Sanitized inventory after verifying the success receipt's owner.
    /// - Throws: Missing capability, malformed/foreign receipt, cancellation or transport failure.
    public func refreshAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        let receipt = try await request(MachineAgentInventoryRefreshRequest(expectedMachineID: machine), timeout: .seconds(28))
        guard receipt.machine == machine else {
            throw DaemonError.malformedResponse("Inventory refresh receipt owner mismatch")
        }
        return receipt.inventory
    }
}
