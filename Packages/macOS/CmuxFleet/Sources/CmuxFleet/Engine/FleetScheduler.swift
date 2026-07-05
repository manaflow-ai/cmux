/// Selects queued Fleet tasks for deterministic dispatch.
public struct FleetScheduler: Sendable {
    /// The maximum number of active agent tasks.
    public var maxConcurrentAgents: Int

    /// The maximum number of tasks provisioning at once.
    public var provisioningCap: Int

    /// Creates a deterministic Fleet scheduler.
    /// - Parameters:
    ///   - maxConcurrentAgents: The maximum number of active agent tasks.
    ///   - provisioningCap: The maximum number of tasks provisioning at once.
    public init(maxConcurrentAgents: Int, provisioningCap: Int = 2) {
        self.maxConcurrentAgents = maxConcurrentAgents
        self.provisioningCap = provisioningCap
    }

    /// Returns queued tasks that can be dispatched without exceeding caps.
    /// - Parameter tasks: The current Fleet task snapshots.
    /// - Returns: Queued tasks ordered by priority, age, and identifier.
    public func dispatch(_ tasks: [FleetTask]) -> [FleetTask] {
        let activeCount = tasks.filter { task in
            switch task.state {
            case .provisioning, .launching, .running, .needsInput:
                true
            case .queued, .stalled, .retryBackoff, .awaitingReview, .done, .failed,
                 .cancelled:
                false
            }
        }.count
        let provisioningCount = tasks.filter { $0.state == .provisioning }.count
        let globalCapacity = max(0, maxConcurrentAgents - activeCount)
        let provisioningCapacity = max(0, provisioningCap - provisioningCount)
        let limit = min(globalCapacity, provisioningCapacity)

        guard limit > 0 else {
            return []
        }

        let sorted = tasks
            .filter { $0.state == .queued && !$0.isBlocked }
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority {
                    switch (lhs.priority, rhs.priority) {
                    case let (left?, right?):
                        return left < right
                    case (_?, nil):
                        return true
                    case (nil, _?):
                        return false
                    case (nil, nil):
                        break
                    }
                }

                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }

                return lhs.id.rawValue < rhs.id.rawValue
            }

        var seen = Set<FleetTaskID>()
        var selected: [FleetTask] = []
        selected.reserveCapacity(limit)
        for task in sorted where seen.insert(task.id).inserted {
            selected.append(task)
            if selected.count == limit {
                break
            }
        }
        return selected
    }
}
