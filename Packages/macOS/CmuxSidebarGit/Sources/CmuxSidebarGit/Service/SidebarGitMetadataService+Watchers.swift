import Foundation
internal import CmuxFileWatch

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
            workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        if let watcher = RecursivePathWatcher(paths: watchedPaths) {
            workspaceGitMetadataWatchersByKey[key] = watcher
            let events = watcher.events
            workspaceGitMetadataWatcherRefreshTasksByKey[key] = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
        }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = request.directory
    }

    func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherRefreshTasksByKey.removeValue(forKey: key)?.cancel()
        // Dropping the last reference runs the watcher's deinit synchronously,
        // which invalidates the FSEventStream on its shared queue before this
        // returns. The consumer task captures the events stream (not the watcher),
        // so removal here is the last reference.
        workspaceGitMetadataWatchersByKey.removeValue(forKey: key)
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
    }
}
