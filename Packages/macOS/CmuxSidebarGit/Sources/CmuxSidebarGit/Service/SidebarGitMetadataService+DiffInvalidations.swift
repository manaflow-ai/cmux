import Foundation
internal import CmuxFoundation
internal import CmuxGit

// MARK: - Git diff invalidation stream and `.git` active-demand tracking.

extension SidebarGitMetadataService {
    /// A stream of coalesced filesystem invalidation events, keyed by
    /// directory, for the git diff panel.
    ///
    /// Each call returns a fresh stream that first replays the most recent
    /// invalidation event per directory (so a panel appearing after a change
    /// still learns about it), then forwards new events as the watchers fire.
    /// Events are deduped per directory: a burst of filesystem changes in one
    /// watcher window yields a single event.
    ///
    /// - Returns: A stream of ``WorkspaceGitInvalidationEvent`` values.
    public func diffInvalidations() -> AsyncStream<WorkspaceGitInvalidationEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            for event in workspaceGitDiffInvalidationBuffer.values {
                continuation.yield(event)
            }
            workspaceGitDiffInvalidationContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.workspaceGitDiffInvalidationContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    /// Registers active `.git`-panel demand for `directory`, keeping a
    /// filesystem watcher alive for it even when left-sidebar git polling is
    /// disabled.
    ///
    /// This is additive to the left-sidebar polling setting, not a replacement:
    /// when polling is enabled the existing watcher is used, and demand only
    /// prevents teardown when polling is off. Registering the same directory
    /// twice is a no-op.
    ///
    /// - Parameter directory: The directory whose git state the panel shows.
    public func registerGitDiffDemand(for directory: String) {
        guard workspaceGitDiffDemandDirectories.insert(directory).inserted else { return }
        ensureWorkspaceGitDiffDemandWatcher(for: directory)
    }

    /// Removes active `.git`-panel demand for `directory`, tearing down its
    /// watcher when no polling and no other demand keep it alive.
    ///
    /// - Parameter directory: The directory whose demand is being released.
    public func unregisterGitDiffDemand(for directory: String) {
        guard workspaceGitDiffDemandDirectories.remove(directory) != nil else { return }
        workspaceGitDiffInvalidationBuffer.removeValue(forKey: directory)
        for watchedPathsKey in Array(workspaceGitDiffDemandDirectoriesByWatchedPathsKey.keys) {
            guard var directories = workspaceGitDiffDemandDirectoriesByWatchedPathsKey[watchedPathsKey],
                  directories.contains(directory) else { continue }
            directories.remove(directory)
            if directories.isEmpty {
                workspaceGitDiffDemandDirectoriesByWatchedPathsKey.removeValue(forKey: watchedPathsKey)
            } else {
                workspaceGitDiffDemandDirectoriesByWatchedPathsKey[watchedPathsKey] = directories
            }
            stopWorkspaceGitMetadataWatcherIfUnused(watchedPathsKey)
        }
    }

    /// Resolves the watch descriptor for a demanded directory and, once known,
    /// backs it with a shared watcher.
    private func ensureWorkspaceGitDiffDemandWatcher(for directory: String) {
        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService else { return }
            let descriptor = await gitMetadataService.watchDescriptor(for: directory)
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitDiffDemandWatcher(descriptor, for: directory)
            }
        }
    }

    private func applyWorkspaceGitDiffDemandWatcher(
        _ descriptor: GitWorkspaceMetadataWatchDescriptor?,
        for directory: String
    ) {
        guard workspaceGitDiffDemandDirectories.contains(directory) else { return }
        guard let descriptor else { return }
        // The diff panel must refresh on ANY work-tree change, including
        // untracked files the sidebar's relevance filter would drop. So the
        // demand watcher uses a permissive filter; the descriptor only supplies
        // the watched roots and coalescing window.
        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(
            paths: descriptor.watchedPaths,
            eventFilterIdentity: nil,
            eventCoalescingInterval: descriptor.eventCoalescingInterval
        )
        workspaceGitDiffDemandDirectoriesByWatchedPathsKey[watchedPathsKey, default: []].insert(directory)
        guard workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] == nil else { return }
        guard let watcher = RecursivePathWatcher(
            paths: descriptor.watchedPaths,
            throttleInterval: descriptor.eventCoalescingInterval
        ) else { return }
        startWorkspaceGitMetadataWatcher(watchedPathsKey: watchedPathsKey, watcher: watcher)
    }

    /// Emits one invalidation event per directory backed by `watchedPathsKey`
    /// (both probe-key source directories and demand directories).
    func emitWorkspaceGitDiffInvalidations(forWatchedPathsKey watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey) {
        var directories = Set(workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey]?.compactMap {
            workspaceGitMetadataWatcherSourceDirectoryByKey[$0]
        } ?? [])
        directories.formUnion(workspaceGitDiffDemandDirectoriesByWatchedPathsKey[watchedPathsKey] ?? [])
        for directory in directories {
            emitWorkspaceGitDiffInvalidation(directory: directory)
        }
    }

    private func emitWorkspaceGitDiffInvalidation(directory: String) {
        let event = WorkspaceGitInvalidationEvent(directory: directory)
        workspaceGitDiffInvalidationBuffer[directory] = event
        for continuation in workspaceGitDiffInvalidationContinuations.values {
            continuation.yield(event)
        }
    }
}
