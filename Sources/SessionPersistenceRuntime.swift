import Foundation

/// Owns process-derived resume indexes used by synchronous lifecycle saves.
/// Refresh work remains asynchronous and coalesced; urgent readers only copy
/// the last completed immutable value.
@MainActor
final class SessionPersistenceRuntime {
    private typealias PendingRefresh = (
        id: UUID,
        task: Task<ProcessDetectedResumeIndexes, Never>
    )

    private(set) var latest: ProcessDetectedResumeIndexes?
    private var pendingRefresh: PendingRefresh?

    init(latest: ProcessDetectedResumeIndexes? = nil) {
        self.latest = latest
    }

    func refresh() async -> ProcessDetectedResumeIndexes {
        await refresh {
            await ProcessDetectedResumeIndexes.load()
        }
    }

    func refresh(
        using loader: @escaping @Sendable () async -> ProcessDetectedResumeIndexes
    ) async -> ProcessDetectedResumeIndexes {
        let pending: PendingRefresh
        if let pendingRefresh {
            pending = pendingRefresh
        } else {
            let id = UUID()
            let task = Task.detached(priority: .utility) {
                await loader()
            }
            pending = (id: id, task: task)
            pendingRefresh = pending
        }

        let refreshed = await pending.task.value
        if pendingRefresh?.id == pending.id {
            latest = refreshed
            pendingRefresh = nil
        }
        return refreshed
    }

    func urgentSavePlan() -> ProcessDetectedResumeIndexSavePlan {
        guard let latest else {
            return ProcessDetectedResumeIndexSavePlan(
                // Passing nil would make AppDelegate's snapshot builder run
                // RestorableAgentSessionIndex.load() synchronously.
                restorableAgentIndex: .empty,
                // Nil preserves live in-memory bindings until an authoritative
                // asynchronous process scan has completed.
                surfaceResumeBindingIndex: nil
            )
        }
        return ProcessDetectedResumeIndexSavePlan(
            restorableAgentIndex: latest.restorableAgentIndex,
            surfaceResumeBindingIndex: latest.surfaceResumeBindingIndex
        )
    }
}
