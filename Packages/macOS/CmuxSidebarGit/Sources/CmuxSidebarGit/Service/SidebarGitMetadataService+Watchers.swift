import Foundation
internal import CmuxFoundation

// MARK: - Filesystem watchers on each tracked directory's git paths.

extension SidebarGitMetadataService {
    func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataWatchEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           workspaceGitMetadataWatchersByKey[key] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            return
        }

        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService else { return }
            let watchedPaths = await gitMetadataService.watchedPaths(for: directory)
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataWatcherDescriptor(
                    watchedPaths,
                    for: key,
                    request: request
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ watchedPaths: [String]?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        guard sidebarGitMetadataWatchEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let watchedPaths else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatchersByKey[key]?.watchedPaths == watchedPaths {
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        if let watcher = RecursivePathWatcher(paths: watchedPaths) {
            workspaceGitMetadataWatchersByKey[key] = watcher
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            let events = watcher.events
            workspaceGitMetadataWatcherRefreshTasksByKey[key] = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.recordWorkspaceGitMetadataFilesystemEvent(for: key)
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
        } else {
            workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
        }
    }

    func workspaceGitSnapshotCacheGeneration(directory: String) -> UInt64? {
        workspaceGitSnapshotCacheGenerationByDirectory[directory]
    }

    func markWorkspaceGitSnapshotCacheEligible(directory: String) {
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        workspaceGitSnapshotCacheGenerationByDirectory[directory] = workspaceGitMetadataFilesystemEventGeneration
    }

    func moveWorkspaceGitSnapshotCacheEligibility(for key: WorkspaceGitProbeKey, to directory: String) {
        let previousDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = directory
        guard previousDirectory != directory else {
            if workspaceGitSnapshotCacheGenerationByDirectory[directory] == nil {
                markWorkspaceGitSnapshotCacheEligible(directory: directory)
            }
            return
        }
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: previousDirectory)
        markWorkspaceGitSnapshotCacheEligible(directory: directory)
    }

    func recordWorkspaceGitMetadataFilesystemEvent(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitMetadataWatcherSourceDirectoryByKey[key] ??
            workspaceGitTrackedDirectoryByKey[key] else {
            return
        }
        guard workspaceGitSnapshotCacheGenerationByDirectory[directory] != nil else {
            return
        }
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        workspaceGitSnapshotCacheGenerationByDirectory[directory] = workspaceGitMetadataFilesystemEventGeneration
    }

    private func removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: String?) {
        guard let directory else { return }
        let hasAnotherWatcher = workspaceGitMetadataWatcherSourceDirectoryByKey.values.contains(directory)
        if !hasAnotherWatcher {
            workspaceGitSnapshotCacheGenerationByDirectory.removeValue(forKey: directory)
        }
    }

    func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherRefreshTasksByKey.removeValue(forKey: key)?.cancel()
        // Dropping the last reference runs the watcher's deinit synchronously,
        // which invalidates the FSEventStream on its shared queue before this
        // returns. The consumer task captures the events stream (not the watcher),
        // so removal here is the last reference.
        workspaceGitMetadataWatchersByKey.removeValue(forKey: key)
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: stoppedDirectory)
    }

    func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = workspaceGitMetadataWatchersByKey.keys.filter { $0.workspaceId == workspaceId }
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    func stopAllWorkspaceGitMetadataWatchers() {
        for task in workspaceGitMetadataWatcherRefreshTasksByKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByKey.removeAll()
        // Dropping the references runs each watcher's deinit synchronously,
        // invalidating its FSEventStream.
        workspaceGitMetadataWatchersByKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
    }
}
