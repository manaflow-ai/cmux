import Foundation

/// Tracks running tunnel tasks so a stop can abort them, with a cap on how
/// many run at once.
actor TunnelTaskSet {
    private let limit: Int
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelled = false

    init(limit: Int) {
        self.limit = limit
    }

    /// Number of tasks running.
    var count: Int { tasks.count }

    /// Runs `body` in a free slot; the slot frees when it returns. Returns
    /// false without running it when every slot is taken or the set was
    /// cancelled.
    func start(_ body: @escaping @Sendable () async -> Void) -> Bool {
        guard !cancelled, tasks.count < limit else { return false }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            await body()
            await self?.finish(id)
        }
        return true
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
    }

    /// Aborts every running task; later `start` calls are refused.
    func cancelAll() {
        cancelled = true
        let running = tasks.values
        tasks.removeAll()
        for task in running { task.cancel() }
    }
}
