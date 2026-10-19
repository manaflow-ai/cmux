public import CmuxNextDaemon

/// Reads one selected machine's inventory without starting an owner or changing routes.
public nonisolated protocol AgentInventoryReader: AnyObject, Sendable {
    /// Verifies the selected public ID before reading its owner's cached observations.
    /// - Parameter machine: The exact catalog ID; never a hostname or UI alias.
    /// - Returns: A partial cached snapshot from that machine.
    /// - Throws: An admission, owner, cancellation or transport failure; never retry elsewhere.
    func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory

    /// Refreshes registry versions while preserving cached installation/sign-in evidence.
    /// - Parameter machine: The exact admitted machine ID, retained across the request.
    /// - Returns: That owner's partial inventory, with per-source observation timestamps.
    /// - Throws: Unsupported, owner, cancellation or transport failures; never fall back.
    func refreshAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory
}

extension AgentInventoryReader {
    /// Refuses refresh on readers that implement only the cache-read contract.
    /// - Parameter machine: The selected owner; no request is sent.
    /// - Returns: No inventory from this default implementation.
    /// - Throws: The missing registry-refresh capability.
    public func refreshAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        throw DaemonError.missingCapabilities(["agent-inventory-refresh-v1"])
    }
}
