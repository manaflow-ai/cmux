public import CmuxNextDaemon

/// Reads one selected machine's cache without starting an owner or changing routes.
public nonisolated protocol AgentInventoryReader: AnyObject, Sendable {
    /// Verifies the selected public ID before reading its owner's cached observations.
    /// - Parameter machine: The exact catalog ID; never a hostname or UI alias.
    /// - Returns: A partial cached snapshot from that machine.
    /// - Throws: An admission, owner, cancellation or transport failure; never retry elsewhere.
    func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory
}
