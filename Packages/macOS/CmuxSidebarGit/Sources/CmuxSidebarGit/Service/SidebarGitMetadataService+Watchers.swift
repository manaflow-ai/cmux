import Foundation
internal import CmuxFoundation

// MARK: - Filesystem watchers on each tracked directory's git paths.

extension SidebarGitMetadataService {
    func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String
    ) {
        guard sidebarGitMetadataActivePollingEnabled else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           let watchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key],
           workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
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

        guard sidebarGitMetadataActivePollingEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let watchedPaths else {
            workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(paths: watchedPaths)
        if workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
            removePendingWorkspaceGitMetadataWatcherRequest(for: key)
            workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            return
        }

        detachWorkspaceGitMetadataWatcherResources(for: key)
        setPendingWorkspaceGitMetadataWatcherRequest(
            request,
            for: key,
            watchedPathsKey: watchedPathsKey
        )
        guard workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey[watchedPathsKey] == nil else {
            return
        }

        let watcherFactory = workspaceGitMetadataWatcherFactory
        workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey[watchedPathsKey] = Task { @MainActor [weak self] in
            let creationTask: Task<RecursivePathWatcher?, Never> = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return nil }
                return watcherFactory(watchedPaths)
            }
            let watcher = await creationTask.value
            guard !Task.isCancelled else {
                if let watcher {
                    await watcher.stop()
                }
                return
            }
            guard let self else {
                if let watcher {
                    await watcher.stop()
                }
                return
            }
            self.finishWorkspaceGitMetadataWatcherCreation(
                watcher,
                forWatchedPathsKey: watchedPathsKey
            )
        }
    }

    private func finishWorkspaceGitMetadataWatcherCreation(
        _ createdWatcher: RecursivePathWatcher?,
        forWatchedPathsKey watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) {
        workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey.removeValue(forKey: watchedPathsKey)
        let pendingRequests = workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey
            .removeValue(forKey: watchedPathsKey) ?? [:]
        for key in pendingRequests.keys
        where workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey[key] == watchedPathsKey {
            workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey.removeValue(forKey: key)
        }
        let validRequests = pendingRequests.filter { key, request in
            workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request
                && sidebarGitMetadataActivePollingEnabled
                && workspaceGitTrackedDirectoryByKey[key] == request.directory
        }
        for key in pendingRequests.keys {
            if let request = pendingRequests[key],
               workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
            }
        }

        guard !validRequests.isEmpty else {
            if let createdWatcher {
                scheduleWorkspaceGitMetadataWatcherTeardown(createdWatcher)
            }
            return
        }

        let watcher: RecursivePathWatcher?
        if let existing = workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] {
            watcher = existing
            if let createdWatcher {
                scheduleWorkspaceGitMetadataWatcherTeardown(createdWatcher)
            }
        } else {
            watcher = createdWatcher
            if let createdWatcher {
                workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] = createdWatcher
                startWorkspaceGitMetadataWatcherEventConsumption(
                    createdWatcher,
                    forWatchedPathsKey: watchedPathsKey
                )
            }
        }

        for (key, request) in validRequests {
            setWorkspaceGitMetadataWatcherSourceDirectory(request.directory, for: key)
            if watcher != nil {
                setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
                moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            } else {
                setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
            }
        }
    }

    func setPendingWorkspaceGitMetadataWatcherRequest(
        _ request: WorkspaceGitMetadataWatcherDescriptorRequest,
        for key: WorkspaceGitProbeKey,
        watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) {
        removePendingWorkspaceGitMetadataWatcherRequest(for: key)
        workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey[watchedPathsKey, default: [:]][key] = request
        workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey[key] = watchedPathsKey
    }

    private func removePendingWorkspaceGitMetadataWatcherRequest(for key: WorkspaceGitProbeKey) {
        guard let watchedPathsKey = workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey
            .removeValue(forKey: key) else {
            return
        }
        workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey[watchedPathsKey]?.removeValue(forKey: key)
        if workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey[watchedPathsKey]?.isEmpty == true {
            workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey.removeValue(forKey: watchedPathsKey)
            workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey
                .removeValue(forKey: watchedPathsKey)?
                .cancel()
        }
    }

    private func startWorkspaceGitMetadataWatcherEventConsumption(
        _ watcher: RecursivePathWatcher,
        forWatchedPathsKey watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) {
        let events = watcher.events
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                let keys = self.recordWorkspaceGitMetadataFilesystemEvent(
                    forWatchedPathsKey: watchedPathsKey
                )
                for key in keys {
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "filesystemEvent"
                    )
                }
            }
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
        setWorkspaceGitMetadataWatcherSourceDirectory(directory, for: key)
        guard previousDirectory != directory else {
            if workspaceGitSnapshotCacheGenerationByDirectory[directory] == nil {
                markWorkspaceGitSnapshotCacheEligible(directory: directory)
            }
            return
        }
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: previousDirectory)
        markWorkspaceGitSnapshotCacheEligible(directory: directory)
    }

    func setWorkspaceGitMetadataWatcherSourceDirectory(_ directory: String?, for key: WorkspaceGitProbeKey) {
        if let previousDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey.removeValue(forKey: key) {
            workspaceGitMetadataWatcherKeysBySourceDirectory[previousDirectory]?.remove(key)
            if workspaceGitMetadataWatcherKeysBySourceDirectory[previousDirectory]?.isEmpty == true {
                workspaceGitMetadataWatcherKeysBySourceDirectory.removeValue(forKey: previousDirectory)
            }
        }
        guard let directory else { return }
        workspaceGitMetadataWatcherSourceDirectoryByKey[key] = directory
        workspaceGitMetadataWatcherKeysBySourceDirectory[directory, default: []].insert(key)
    }

    func setWorkspaceGitMetadataWatcherWatchedPathsKey(
        _ watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey?,
        for key: WorkspaceGitProbeKey
    ) {
        if let previousWatchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key],
           previousWatchedPathsKey == watchedPathsKey {
            return
        }
        if let previousWatchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeValue(forKey: key) {
            workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[previousWatchedPathsKey]?.remove(key)
            if workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[previousWatchedPathsKey]?.isEmpty == true {
                workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeValue(forKey: previousWatchedPathsKey)
                workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey
                    .removeValue(forKey: previousWatchedPathsKey)?
                    .cancel()
                if let watcher = workspaceGitMetadataWatchersByWatchedPathsKey
                    .removeValue(forKey: previousWatchedPathsKey) {
                    scheduleWorkspaceGitMetadataWatcherTeardown(watcher)
                }
            }
        }
        guard let watchedPathsKey else { return }
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key] = watchedPathsKey
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey, default: []].insert(key)
    }

    func recordWorkspaceGitMetadataFilesystemEvent(for key: WorkspaceGitProbeKey) {
        guard let directory = workspaceGitMetadataWatcherSourceDirectoryByKey[key] ??
            workspaceGitTrackedDirectoryByKey[key] else {
            return
        }
        recordWorkspaceGitMetadataFilesystemEvent(directory: directory)
    }

    @discardableResult
    func recordWorkspaceGitMetadataFilesystemEvent(
        forWatchedPathsKey watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) -> [WorkspaceGitProbeKey] {
        let keys = Array(workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey] ?? [])
        let directories = Set(keys.compactMap { workspaceGitMetadataWatcherSourceDirectoryByKey[$0] })
        advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directories: directories)
        return keys
    }

    func advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directory: String) {
        guard workspaceGitSnapshotCacheGenerationByDirectory[directory] != nil else {
            return
        }
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        workspaceGitSnapshotCacheGenerationByDirectory[directory] = workspaceGitMetadataFilesystemEventGeneration
    }

    private func advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directories: Set<String>) {
        let eligibleDirectories = directories.filter {
            workspaceGitSnapshotCacheGenerationByDirectory[$0] != nil
        }
        guard !eligibleDirectories.isEmpty else {
            return
        }
        workspaceGitMetadataFilesystemEventGeneration &+= 1
        let generation = workspaceGitMetadataFilesystemEventGeneration
        for directory in eligibleDirectories {
            workspaceGitSnapshotCacheGenerationByDirectory[directory] = generation
        }
    }

    private func recordWorkspaceGitMetadataFilesystemEvent(directory: String) {
        advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directory: directory)
    }

    private func removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: String?) {
        guard let directory else { return }
        if workspaceGitMetadataWatcherKeysBySourceDirectory[directory]?.isEmpty != false {
            workspaceGitSnapshotCacheGenerationByDirectory.removeValue(forKey: directory)
        }
    }

    func stopWorkspaceGitMetadataWatcher(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        removePendingWorkspaceGitMetadataWatcherRequest(for: key)
        detachWorkspaceGitMetadataWatcherResources(for: key)
    }

    private func detachWorkspaceGitMetadataWatcherResources(for key: WorkspaceGitProbeKey) {
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        setWorkspaceGitMetadataWatcherSourceDirectory(nil, for: key)
        setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: stoppedDirectory)
    }

    private func scheduleWorkspaceGitMetadataWatcherTeardown(_ watcher: RecursivePathWatcher) {
        let taskID = UUID()
        workspaceGitMetadataWatcherTeardownTasksByID[taskID] = Task { @MainActor [weak self] in
            await watcher.stop()
            self?.workspaceGitMetadataWatcherTeardownTasksByID.removeValue(forKey: taskID)
        }
    }

    func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = Set(workspaceGitMetadataWatcherSourceDirectoryByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherDescriptorRequestsByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey.keys.filter {
                $0.workspaceId == workspaceId
            })
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    func stopAllWorkspaceGitMetadataWatchers() {
        for task in workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherCreationTasksByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherPendingRequestsByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherPendingWatchedPathsKeyByProbeKey.removeAll()
        for task in workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.removeAll()
        for watcher in workspaceGitMetadataWatchersByWatchedPathsKey.values {
            scheduleWorkspaceGitMetadataWatcherTeardown(watcher)
        }
        workspaceGitMetadataWatchersByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherKeysBySourceDirectory.removeAll()
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeAll()
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
    }
}
