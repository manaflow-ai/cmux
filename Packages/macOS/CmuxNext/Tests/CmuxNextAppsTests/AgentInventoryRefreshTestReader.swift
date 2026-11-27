import CmuxNextApps
import CmuxNextDaemon

/// Keeps explicit refreshes distinguishable from ordinary cache reads.
actor AgentInventoryRefreshTestReader: AgentInventoryReader {
    let snapshot: AcpmuxHarnessInventory
    let error: DaemonError?
    let onRefresh: @Sendable () async -> Void
    private(set) var reads: [ResourceID] = []
    private(set) var refreshes: [ResourceID] = []

    init(snapshot: AcpmuxHarnessInventory, error: DaemonError? = nil,
         onRefresh: @escaping @Sendable () async -> Void = {}) {
        self.snapshot = snapshot
        self.error = error
        self.onRefresh = onRefresh
    }

    func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        reads.append(machine)
        return snapshot
    }

    func refreshAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        refreshes.append(machine)
        await onRefresh()
        if let error { throw error }
        return snapshot
    }
}
