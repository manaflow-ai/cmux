import Foundation
internal import CmuxFoundation
internal import CmuxGit
internal import os

// MARK: - Filesystem watchers on each tracked directory's git paths.

extension SidebarGitMetadataService {
    func updateWorkspaceGitMetadataWatcher(
        for key: WorkspaceGitProbeKey,
        directory: String,
        forceDescriptorRefresh: Bool = false
    ) {
        guard sidebarGitMetadataActivePollingEnabled || workspaceGitDiffDemandDirectories.contains(directory) else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if !forceDescriptorRefresh,
           workspaceGitMetadataWatcherSourceDirectoryByKey[key] == directory,
           let watchedPathsKey = workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey[key],
           workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
            if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory != directory {
                workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
                workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key)
            }
            return
        }

        if workspaceGitMetadataWatcherDescriptorRequestsByKey[key]?.directory == directory {
            if forceDescriptorRefresh {
                workspaceGitMetadataWatcherDescriptorInvalidatedKeys.insert(key)
            }
            return
        }

        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key)
        workspaceGitMetadataWatcherDescriptorGeneration &+= 1
        let request = WorkspaceGitMetadataWatcherDescriptorRequest(
            generation: workspaceGitMetadataWatcherDescriptorGeneration,
            directory: directory
        )
        workspaceGitMetadataWatcherDescriptorRequestsByKey[key] = request

        Task { [weak self] in
            guard let gitMetadataService = self?.gitMetadataService else { return }
            let descriptor = await gitMetadataService.watchDescriptor(for: directory)
            await MainActor.run { [weak self] in
                self?.applyWorkspaceGitMetadataWatcherDescriptor(
                    descriptor,
                    for: key,
                    request: request
                )
            }
        }
    }

    private func applyWorkspaceGitMetadataWatcherDescriptor(
        _ descriptor: GitWorkspaceMetadataWatchDescriptor?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else {
            return
        }
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)

        if workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key) != nil {
            guard sidebarGitMetadataActivePollingEnabled || workspaceGitDiffDemandDirectories.contains(request.directory),
                  workspaceGitTrackedDirectoryByKey[key] == request.directory else {
                stopWorkspaceGitMetadataWatcher(for: key)
                return
            }
            updateWorkspaceGitMetadataWatcher(
                for: key,
                directory: request.directory,
                forceDescriptorRefresh: true
            )
            return
        }

        guard sidebarGitMetadataActivePollingEnabled || workspaceGitDiffDemandDirectories.contains(request.directory),
              workspaceGitTrackedDirectoryByKey[key] == request.directory,
              let descriptor else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return
        }

        if let degradation = descriptor.degradation,
           workspaceGitMetadataDegradationLoggedRepositoryRoots.insert(descriptor.repositoryRoot).inserted {
            let message = "workspace.gitWatch.degraded " + degradation.logDescription
            debugLog(message)
            Self.gitWatchDiagnosticsLogger.info("\(message, privacy: .public)")
        }

        let watchedPathsKey = WorkspaceGitMetadataWatchedPathsKey(
            paths: descriptor.watchedPaths,
            eventFilterIdentity: descriptor.eventFilterIdentity,
            eventCoalescingInterval: descriptor.eventCoalescingInterval
        )
        if workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            return
        }

        stopWorkspaceGitMetadataWatcher(for: key)
        if let watcher = RecursivePathWatcher(
            paths: descriptor.watchedPaths,
            throttleInterval: descriptor.eventCoalescingInterval,
            eventFilter: { descriptor.containsRelevantChange(
                paths: $0.paths,
                requiresFullRescan: $0.requiresFullRescan
            ) }
        ) {
            workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] = watcher
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            let events = watcher.pathEvents
            workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = Task { @MainActor [weak self] in
                for await change in events {
                    guard let self else { break }
                    // The watcher key includes the immutable filter identity,
                    // watched roots, and throttle. Its event filter has already
                    // evaluated this batch once, so every attached probe shares
                    // the same relevance result.
                    let keys = Array(
                        self.workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey] ?? []
                    )
                    guard !keys.isEmpty else { continue }
                    self.recordWorkspaceGitMetadataFilesystemEvent(for: keys)
                    self.emitWorkspaceGitDiffInvalidations(forWatchedPathsKey: watchedPathsKey)
                    for key in keys {
                        self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                            workspaceId: key.workspaceId,
                            panelId: key.panelId,
                            reason: "filesystemEvent"
                        )
                    }
                    guard descriptor.containsGitMetadataChange(
                        paths: change.paths,
                        requiresFullRescan: change.requiresFullRescan
                    ) else {
                        continue
                    }
                    for key in keys {
                        guard let directory = self.workspaceGitMetadataWatcherSourceDirectoryByKey[key] else {
                            continue
                        }
                        self.updateWorkspaceGitMetadataWatcher(
                            for: key,
                            directory: directory,
                            forceDescriptorRefresh: true
                        )
                    }
                }
            }
        } else {
            setWorkspaceGitMetadataWatcherSourceDirectory(request.directory, for: key)
            setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
        }
    }

    /// Creates a shared watcher for `watchedPathsKey` and starts its refresh
    /// task, which schedules sidebar probes and emits git-diff invalidations.
    func startWorkspaceGitMetadataWatcher(
        watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey,
        watcher: RecursivePathWatcher
    ) {
        workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] = watcher
        let events = watcher.events
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                let keys = self.recordWorkspaceGitMetadataFilesystemEvent(
                    forWatchedPathsKey: watchedPathsKey
                )
                self.emitWorkspaceGitDiffInvalidations(forWatchedPathsKey: watchedPathsKey)
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
                stopWorkspaceGitMetadataWatcherIfUnused(previousWatchedPathsKey)
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
        recordWorkspaceGitMetadataFilesystemEvent(for: keys)
        return keys
    }

    private func recordWorkspaceGitMetadataFilesystemEvent(for keys: [WorkspaceGitProbeKey]) {
        let directories = Set(keys.compactMap { workspaceGitMetadataWatcherSourceDirectoryByKey[$0] })
        advanceWorkspaceGitSnapshotCacheGenerationIfEligible(directories: directories)
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
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key)
        setWorkspaceGitMetadataWatcherSourceDirectory(nil, for: key)
        setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: stoppedDirectory)
    }

    /// Tears down a shared watcher when no probe key and no git-diff demand
    /// still back it. Dropping the last watcher reference invalidates the
    /// FSEventStream.
    func stopWorkspaceGitMetadataWatcherIfUnused(_ watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey) {
        let hasProbeKeys = !(workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey]?.isEmpty ?? true)
        let hasDemand = !(workspaceGitDiffDemandDirectoriesByWatchedPathsKey[watchedPathsKey]?.isEmpty ?? true)
        guard !hasProbeKeys, !hasDemand else { return }
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.removeValue(forKey: watchedPathsKey)?.cancel()
        workspaceGitMetadataWatchersByWatchedPathsKey.removeValue(forKey: watchedPathsKey)
    }

    func stopWorkspaceGitMetadataWatchers(workspaceId: UUID) {
        let keys = Set(workspaceGitMetadataWatcherSourceDirectoryByKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.keys.filter { $0.workspaceId == workspaceId })
            .union(workspaceGitMetadataWatcherDescriptorRequestsByKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    func stopAllWorkspaceGitMetadataWatchers() {
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherKeysBySourceDirectory.removeAll()
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeAll()
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
        // Tear down watchers not backed by active git-diff demand.
        for watchedPathsKey in Array(workspaceGitMetadataWatchersByWatchedPathsKey.keys) {
            stopWorkspaceGitMetadataWatcherIfUnused(watchedPathsKey)
        }
    }
}
