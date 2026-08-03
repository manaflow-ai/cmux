import Foundation

struct ProcessDetectedResumeIndexes: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex

    static func load(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) async -> ProcessDetectedResumeIndexes {
        await Task.detached(priority: .utility) {
            loadSynchronously(homeDirectory: homeDirectory, fileManager: fileManager, maximumSnapshotAge: 5)
        }.value
    }

    static func loadSynchronously(
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default,
        maximumSnapshotAge: TimeInterval? = nil
    ) -> ProcessDetectedResumeIndexes {
        let capturedAt = Date().timeIntervalSince1970
        let processSnapshot = if let maximumSnapshotAge {
            CmuxTopProcessSnapshot.captureCached(includeProcessDetails: true, maximumAge: maximumSnapshotAge)
        } else {
            CmuxTopProcessSnapshot.capture(includeProcessDetails: true)
        }
        let registry = CmuxVaultAgentRegistry.load(homeDirectory: homeDirectory, fileManager: fileManager)
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        let restorableAgentIndex = RestorableAgentSessionIndex.load(
            homeDirectory: homeDirectory,
            fileManager: fileManager,
            registry: registry,
            detectedSnapshots: detectedSnapshots
        )
        let detectedBindings = SurfaceResumeBindingIndex.processDetectedTmuxBindings(
            fileManager: fileManager,
            processSnapshot: processSnapshot,
            capturedAt: capturedAt
        )
        return ProcessDetectedResumeIndexes(
            restorableAgentIndex: restorableAgentIndex,
            surfaceResumeBindingIndex: SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
        )
    }
}

struct ProcessDetectedResumeIndexSavePlan: Sendable {
    let restorableAgentIndex: RestorableAgentSessionIndex
    let surfaceResumeBindingIndex: SurfaceResumeBindingIndex?
}

/// Keeps immutable process-derived indexes ready for lifecycle callbacks that
/// must finish synchronously. Refresh work remains asynchronous and coalesced;
/// urgent readers only copy the last completed value.
@MainActor
final class ProcessDetectedResumeIndexesCache {
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
