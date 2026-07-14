import CmuxFoundation
import Foundation

/// Owns shallow file watchers for one repository's worktree-list metadata.
@MainActor
final class WorktreeSidebarListingWatcher {
    private let snapshotLoader: WorktreeSidebarListingMetadataSnapshotLoader
    private var generation: UInt64 = 0
    private var plan = WorktreeSidebarListingWatchPlan.empty
    private var snapshot: WorktreeSidebarListingMetadataSnapshot?
    private var watchers: [FileWatcher] = []
    private var tasks: [Task<Void, Never>] = []

    init(
        snapshotLoader: WorktreeSidebarListingMetadataSnapshotLoader =
            WorktreeSidebarListingMetadataSnapshotLoader()
    ) {
        self.snapshotLoader = snapshotLoader
    }

    func reconcile(
        plan: WorktreeSidebarListingWatchPlan,
        onEvent: @escaping @MainActor @Sendable () -> Void
    ) async {
        guard self.plan != plan else { return }
        generation &+= 1
        let expectedGeneration = generation
        let previousWatchers = detach()
        for watcher in previousWatchers { await watcher.stop() }
        let snapshot = await snapshotLoader.load(plan: plan)
        guard !Task.isCancelled, generation == expectedGeneration else { return }

        self.plan = plan
        self.snapshot = snapshot
        let watchers = plan.shallowPaths.map {
            FileWatcher(path: $0, throttle: .milliseconds(250))
        }
        self.watchers = watchers
        tasks = watchers.map { watcher in
            Task { @MainActor [weak self] in
                for await _ in watcher.events {
                    guard let self, !Task.isCancelled else { break }
                    await self.handleEvent(
                        expectedPlan: plan,
                        onEvent: onEvent
                    )
                }
            }
        }
    }

    func stop() {
        generation &+= 1
        let previousWatchers = detach()
        guard !previousWatchers.isEmpty else { return }
        Task {
            for watcher in previousWatchers { await watcher.stop() }
        }
    }

    private func handleEvent(
        expectedPlan: WorktreeSidebarListingWatchPlan,
        onEvent: @MainActor @Sendable () -> Void
    ) async {
        let expectedGeneration = generation
        let updatedSnapshot = await snapshotLoader.load(plan: expectedPlan)
        guard generation == expectedGeneration,
              plan == expectedPlan,
              snapshot != updatedSnapshot else {
            return
        }
        snapshot = updatedSnapshot
        onEvent()
    }

    private func detach() -> [FileWatcher] {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        plan = .empty
        snapshot = nil
        let previousWatchers = watchers
        watchers.removeAll()
        return previousWatchers
    }

    deinit {
        tasks.forEach { $0.cancel() }
        let previousWatchers = watchers
        Task {
            for watcher in previousWatchers { await watcher.stop() }
        }
    }
}
