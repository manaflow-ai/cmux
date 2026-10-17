import CmuxNextApps
import CmuxNextDaemon

/// An existing carrier whose read and admission changes are controlled by the test.
actor AgentInventoryTestReader: AgentInventoryReader {
    let snapshot: AcpmuxHarnessInventory
    let error: DaemonError?
    let onRead: @Sendable () async -> Void
    private(set) var requests: [ResourceID] = []

    init(snapshot: AcpmuxHarnessInventory, error: DaemonError? = nil,
         onRead: @escaping @Sendable () async -> Void = {}) {
        self.snapshot = snapshot
        self.error = error
        self.onRead = onRead
    }

    func readAgentInventory(machine: ResourceID) async throws -> AcpmuxHarnessInventory {
        try Task.checkCancellation()
        requests.append(machine)
        await onRead()
        try Task.checkCancellation()
        if let error { throw error }
        return snapshot
    }
}
