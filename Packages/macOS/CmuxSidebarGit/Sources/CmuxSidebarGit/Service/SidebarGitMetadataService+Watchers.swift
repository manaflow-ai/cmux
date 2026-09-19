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
        guard sidebarGitMetadataActivePollingEnabled else {
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

        workspaceGitMetadataWatcherTasksByKey[key]?.cancel()
        let reader = gitMetadataService
        let makeWatcher = makeWatcher
        workspaceGitMetadataWatcherTasksByKey[key] = Task { [weak self] in
            let descriptor = await reader.watchDescriptor(for: directory)
            guard !Task.isCancelled,
                  self?.prepareWorkspaceGitMetadataWatcher(descriptor, for: key, request: request) == true,
                  let descriptor else { return }
            let watcher = await makeWatcher(descriptor)
            self?.installWorkspaceGitMetadataWatcher(watcher, descriptor: descriptor, for: key, request: request)
        }
    }

    /// Validates the requested generation before doing native registration.
    private func prepareWorkspaceGitMetadataWatcher(
        _ descriptor: GitWorkspaceMetadataWatchDescriptor?,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) -> Bool {
        guard acceptWorkspaceGitMetadataWatcherRequest(for: key, request: request) else { return false }
        guard let descriptor else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return false
        }
        let watchedPathsKey = watchedPathsKey(for: descriptor)
        if workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
            finishWorkspaceGitMetadataWatcherRequest(for: key)
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            logWatcherDegradationIfNeeded(for: descriptor)
            return false
        }
        // Keep the old watcher live until the replacement has registered.
        return true
    }

    /// Runs without suspension so no older success or failure can retire newer state.
    private func installWorkspaceGitMetadataWatcher(
        _ watcher: RecursivePathWatcher?,
        descriptor: GitWorkspaceMetadataWatchDescriptor,
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) {
        guard acceptWorkspaceGitMetadataWatcherRequest(for: key, request: request) else { return }
        let watchedPathsKey = watchedPathsKey(for: descriptor)
        if workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] != nil {
            // Another panel completed the same registration while this one was
            // suspended. Preserve its one event consumer and discard our duplicate.
            finishWorkspaceGitMetadataWatcherRequest(for: key)
            setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
            moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
            return
        }
        guard let watcher else {
            // A failed replacement must leave the currently installed watcher
            // and its event consumer authoritative until a later registration
            // succeeds. Only retire the pending request itself.
            finishWorkspaceGitMetadataWatcherRequest(for: key)
            return
        }
        finishWorkspaceGitMetadataWatcherRequest(for: key)
        workspaceGitMetadataWatchersByWatchedPathsKey[watchedPathsKey] = watcher
        setWorkspaceGitMetadataWatcherWatchedPathsKey(watchedPathsKey, for: key)
        moveWorkspaceGitSnapshotCacheEligibility(for: key, to: request.directory)
        logWatcherDegradationIfNeeded(for: descriptor)
        consumeWorkspaceGitMetadataWatcherEvents(watcher, descriptor: descriptor, watchedPathsKey: watchedPathsKey)
    }

    private func watchedPathsKey(
        for descriptor: GitWorkspaceMetadataWatchDescriptor
    ) -> WorkspaceGitMetadataWatchedPathsKey {
        WorkspaceGitMetadataWatchedPathsKey(
            paths: descriptor.watchedPaths,
            eventFilterIdentity: descriptor.eventFilterIdentity,
            eventCoalescingInterval: descriptor.eventCoalescingInterval
        )
    }

    private func finishWorkspaceGitMetadataWatcherRequest(for key: WorkspaceGitProbeKey) {
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherTasksByKey.removeValue(forKey: key)
    }

    private func acceptWorkspaceGitMetadataWatcherRequest(
        for key: WorkspaceGitProbeKey,
        request: WorkspaceGitMetadataWatcherDescriptorRequest
    ) -> Bool {
        guard workspaceGitMetadataWatcherDescriptorRequestsByKey[key] == request else { return false }
        guard sidebarGitMetadataActivePollingEnabled,
              workspaceGitTrackedDirectoryByKey[key] == request.directory else {
            stopWorkspaceGitMetadataWatcher(for: key)
            return false
        }
        if workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key) != nil {
            finishWorkspaceGitMetadataWatcherRequest(for: key)
            updateWorkspaceGitMetadataWatcher(for: key, directory: request.directory, forceDescriptorRefresh: true)
            return false
        }
        return true
    }

    private func consumeWorkspaceGitMetadataWatcherEvents(
        _ watcher: RecursivePathWatcher,
        descriptor: GitWorkspaceMetadataWatchDescriptor,
        watchedPathsKey: WorkspaceGitMetadataWatchedPathsKey
    ) {
        let events = watcher.pathEvents
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey[watchedPathsKey] = Task { @MainActor [weak self] in
            for await change in events {
                guard let self, !Task.isCancelled else { break }
                let keys = Array(workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey[watchedPathsKey] ?? [])
                guard !keys.isEmpty else { continue }
                recordWorkspaceGitMetadataFilesystemEvent(for: keys)
                for key in keys {
                    scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId, panelId: key.panelId, reason: "filesystemEvent"
                    )
                }
                guard descriptor.containsGitMetadataChange(
                    paths: change.paths, requiresFullRescan: change.requiresFullRescan
                ) else { continue }
                for key in keys {
                    guard let directory = workspaceGitMetadataWatcherSourceDirectoryByKey[key] else { continue }
                    updateWorkspaceGitMetadataWatcher(for: key, directory: directory, forceDescriptorRefresh: true)
                }
            }
        }
    }

    private func logWatcherDegradationIfNeeded(
        for descriptor: GitWorkspaceMetadataWatchDescriptor
    ) {
        guard let degradation = descriptor.degradation,
              workspaceGitMetadataDegradationLoggedRepositoryRoots
                  .insert(descriptor.repositoryRoot)
                  .inserted else {
            return
        }
        let message = "workspace.gitWatch.degraded " + degradation.logDescription
        debugLog(message)
        Self.gitWatchDiagnosticsLogger.info("\(message, privacy: .public)")
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
                // Dropping the last reference queues native cleanup without blocking this actor.
                workspaceGitMetadataWatchersByWatchedPathsKey.removeValue(forKey: previousWatchedPathsKey)
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
        workspaceGitMetadataWatcherTasksByKey.removeValue(forKey: key)?.cancel()
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeValue(forKey: key)
        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.remove(key)
        setWorkspaceGitMetadataWatcherSourceDirectory(nil, for: key)
        setWorkspaceGitMetadataWatcherWatchedPathsKey(nil, for: key)
        removeWorkspaceGitSnapshotCacheEligibilityIfUnused(directory: stoppedDirectory)
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
        for task in workspaceGitMetadataWatcherTasksByKey.values { task.cancel() }
        workspaceGitMetadataWatcherTasksByKey.removeAll()
        for task in workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.removeAll()
        // Dropping references queues native cleanup without blocking this actor.
        workspaceGitMetadataWatchersByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherKeysBySourceDirectory.removeAll()
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeAll()
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
    }
}
