public import CmuxNextDaemon

extension DaemonConnection: AgentInventoryReader {
    /// Reads the selected machine's cache through the negotiated native owner check.
    /// - Parameter machine: The public machine ID selected by the caller.
    /// - Returns: Cached observations from exactly that owner.
    /// - Throws: Unsupported, mismatched, unavailable or cancelled reads, without fallback.
    public func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        try await request(MachineAgentInventoryRequest(expectedMachineID: machine), timeout: .seconds(15))
    }
}
