import Foundation

/// Merges provider snapshots while retaining bounded completed workload history.
struct AgentSessionWorkloadReconciler: Sendable {
    private let maximumRecords = 256

    func replacingActiveWorkloads(
        _ existing: [AgentWorkloadRecord],
        with incoming: [AgentWorkloadRecord],
        now: TimeInterval
    ) -> [AgentWorkloadRecord] {
        let incomingIDs = Set(incoming.map(\.id))
        var merged = existing.map { workload -> AgentWorkloadRecord in
            guard workload.phase.isActive, !incomingIDs.contains(workload.id) else { return workload }
            var completed = workload
            completed.phase = .completed
            completed.updatedAt = now
            completed.endedAt = now
            completed.endReason = "provider_completed"
            return completed
        }
        for workload in incoming {
            if let index = merged.firstIndex(where: { $0.id == workload.id }) {
                let originalStartedAt = merged[index].startedAt
                merged[index] = workload
                merged[index].startedAt = min(originalStartedAt, workload.startedAt)
            } else {
                merged.append(workload)
            }
        }
        return bounded(merged)
    }

    func cancellingActiveWorkloads(
        _ existing: [AgentWorkloadRecord],
        reason: String,
        now: TimeInterval
    ) -> [AgentWorkloadRecord] {
        bounded(existing.map { workload in
            guard workload.phase.isActive else { return workload }
            var cancelled = workload
            cancelled.phase = .cancelled
            cancelled.updatedAt = now
            cancelled.endedAt = now
            cancelled.endReason = reason
            return cancelled
        })
    }

    private func bounded(_ records: [AgentWorkloadRecord]) -> [AgentWorkloadRecord] {
        guard records.count > maximumRecords else { return records }
        let active = records.filter { $0.phase.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        if active.count >= maximumRecords {
            return Array(active.prefix(maximumRecords))
        }
        let inactive = records.filter { !$0.phase.isActive }.sorted { $0.updatedAt > $1.updatedAt }
        return active + Array(inactive.prefix(maximumRecords - active.count))
    }
}
