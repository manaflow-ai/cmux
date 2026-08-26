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
            guard sidebarGitMetadataActivePollingEnabled,
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

        guard sidebarGitMetadataActivePollingEnabled,
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
            updateWorkspaceGitMetadataCreationWatchers(
                for: key,
                paths: descriptor.creationWatchPaths
            )
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
        updateWorkspaceGitMetadataCreationWatchers(
            for: key,
            paths: descriptor.creationWatchPaths
        )
    }

    private func updateWorkspaceGitMetadataCreationWatchers(
        for key: WorkspaceGitProbeKey,
        paths: [String]
    ) {
        let normalizedPaths = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let previousPaths = workspaceGitMetadataCreationWatchPathsByProbeKey[key] ?? []
        for path in previousPaths.subtracting(normalizedPaths) {
            removeWorkspaceGitMetadataCreationWatchTarget(path, for: key)
        }

        var acceptedPaths: Set<String> = []
        for path in normalizedPaths {
            if previousPaths.contains(path) || addWorkspaceGitMetadataCreationWatchTarget(path, for: key) {
                acceptedPaths.insert(path)
            }
        }
        workspaceGitMetadataCreationWatchPathsByProbeKey[key] = acceptedPaths
    }

    private func stopWorkspaceGitMetadataCreationWatchers(for key: WorkspaceGitProbeKey) {
        let paths = workspaceGitMetadataCreationWatchPathsByProbeKey.removeValue(forKey: key) ?? []
        for path in paths {
            removeWorkspaceGitMetadataCreationWatchTarget(path, for: key)
        }
    }

    private func addWorkspaceGitMetadataCreationWatchTarget(
        _ path: String,
        for key: WorkspaceGitProbeKey
    ) -> Bool {
        let ancestor = nearestExistingDirectory(for: path)
        guard ancestor != "/" else { return false }
        let targetIsNew = workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] == nil
        if targetIsNew {
            let targetCount = workspaceGitMetadataCreationWatcherAncestorByTargetPath.count
            guard targetCount < 512 else { return false }
            let ancestorIsNew = workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor] == nil
            if ancestorIsNew {
                guard workspaceGitMetadataCreationWatchersByAncestor.count < 128 else {
                    return false
                }
            }
            workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] = ancestor
            workspaceGitMetadataCreationWatchTargetExistsByPath[path] =
                creationWatchFileManager.fileExists(atPath: path)
            workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor, default: []].insert(path)
        }
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[path, default: []].insert(key)
        ensureWorkspaceGitMetadataCreationWatcher(for: ancestor)
        return true
    }

    private func removeWorkspaceGitMetadataCreationWatchTarget(
        _ path: String,
        for key: WorkspaceGitProbeKey
    ) {
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[path]?.remove(key)
        guard workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[path]?.isEmpty == true else {
            return
        }
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath.removeValue(forKey: path)
        workspaceGitMetadataCreationWatcherTargetExistsByPath.removeValue(forKey: path)
        guard let ancestor = workspaceGitMetadataCreationWatcherAncestorByTargetPath.removeValue(forKey: path) else {
            return
        }
        workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor]?.remove(path)
        if workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor]?.isEmpty == true {
            workspaceGitMetadataCreationWatchTargetsByAncestor.removeValue(forKey: ancestor)
            workspaceGitMetadataCreationWatcherTasksByAncestor.removeValue(forKey: ancestor)?.cancel()
            workspaceGitMetadataCreationWatchersByAncestor.removeValue(forKey: ancestor)
        }
    }

    private func ensureWorkspaceGitMetadataCreationWatcher(for ancestor: String) {
        guard workspaceGitMetadataCreationWatchersByAncestor[ancestor] == nil else { return }
        let watcher = FileWatcher(
            path: ancestor,
            throttle: .milliseconds(250),
            allowsFilesystemRootAncestor: false,
            fileManager: creationWatchFileManager
        )
        workspaceGitMetadataCreationWatchersByAncestor[ancestor] = watcher
        let events = watcher.events
        workspaceGitMetadataCreationWatcherTasksByAncestor[ancestor] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                let targets = Array(
                    self.workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor] ?? []
                )
                let snapshots = await self.creationTargetSnapshots(for: targets)
                guard !Task.isCancelled else { break }
                var changed = false
                for target in targets {
                    guard self.workspaceGitMetadataCreationWatcherAncestorByTargetPath[target]
                            == ancestor,
                          let snapshot = snapshots[target] else {
                        continue
                    }
                    let closerAncestor = snapshot.nearestExistingDirectory
                    if closerAncestor != ancestor, closerAncestor != "/" {
                        self.migrateWorkspaceGitMetadataCreationWatchTarget(
                            target,
                            from: ancestor,
                            to: closerAncestor
                        )
                    }
                    if self.workspaceGitMetadataCreationWatcherTargetExistsByPath[target]
                        != snapshot.exists {
                        self.workspaceGitMetadataCreationWatcherTargetExistsByPath[target] =
                            snapshot.exists
                        changed = true
                    }
                }
                guard changed else { continue }
                let keySet = targets.reduce(into: Set<WorkspaceGitProbeKey>()) { result, target in
                    result.formUnion(
                        self.workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[target] ?? []
                    )
                }
                let keys = Array(keySet)
                guard !keys.isEmpty else { continue }
                self.recordWorkspaceGitMetadataFilesystemEvent(for: keys)
                for key in keys {
                    self.scheduleWorkspaceGitMetadataRefreshIfPossible(
                        workspaceId: key.workspaceId,
                        panelId: key.panelId,
                        reason: "configCreationEvent"
                    )
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
    }

    private func migrateWorkspaceGitMetadataCreationWatchTarget(
        _ target: String,
        from previousAncestor: String,
        to ancestor: String
    ) {
        let removesPreviousWatcher =
            workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.count == 1
        guard workspaceGitMetadataCreationWatcherAncestorByTargetPath[target] == previousAncestor,
              workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor] != nil
                || workspaceGitMetadataCreationWatchersByAncestor.count < 128
                || removesPreviousWatcher else {
            return
        }
        workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.remove(target)
        if workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.isEmpty == true {
            workspaceGitMetadataCreationWatchTargetsByAncestor.removeValue(forKey: previousAncestor)
            workspaceGitMetadataCreationWatcherTasksByAncestor
                .removeValue(forKey: previousAncestor)?
                .cancel()
            workspaceGitMetadataCreationWatchersByAncestor.removeValue(forKey: previousAncestor)
        }
        workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor, default: []].insert(target)
        workspaceGitMetadataCreationWatcherAncestorByTargetPath[target] = ancestor
        ensureWorkspaceGitMetadataCreationWatcher(for: ancestor)
    }

    @concurrent
    nonisolated private func creationTargetSnapshots(
        for paths: [String]
    ) async -> [String: WorkspaceGitMetadataCreationTargetSnapshot] {
        paths.reduce(into: [String: WorkspaceGitMetadataCreationTargetSnapshot]()) { result, path in
            result[path] = WorkspaceGitMetadataCreationTargetSnapshot(
                exists: creationWatchFileManager.fileExists(atPath: path),
                nearestExistingDirectory: nearestExistingDirectory(for: path)
            )
        }
    }

    nonisolated private func nearestExistingDirectory(for path: String) -> String {
        var candidate = URL(fileURLWithPath: path).deletingLastPathComponent()
        while candidate.path != "/" {
            var isDirectory: ObjCBool = false
            if creationWatchFileManager.fileExists(
                atPath: candidate.path,
                isDirectory: &isDirectory
            ),
               isDirectory.boolValue {
                return candidate
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
            }
            candidate.deleteLastPathComponent()
        }
        return "/"
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
                // Dropping the last watcher reference invalidates the FSEventStream.
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
        let stoppedDirectory = workspaceGitMetadataWatcherSourceDirectoryByKey[key]
        stopWorkspaceGitMetadataCreationWatchers(for: key)
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
            .union(workspaceGitMetadataCreationWatchPathsByProbeKey.keys.filter { $0.workspaceId == workspaceId })
        for key in keys {
            stopWorkspaceGitMetadataWatcher(for: key)
        }
    }

    func stopAllWorkspaceGitMetadataWatchers() {
        for task in workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.values {
            task.cancel()
        }
        workspaceGitMetadataWatcherRefreshTasksByWatchedPathsKey.removeAll()
        // Dropping the references runs each watcher's deinit synchronously,
        // invalidating its FSEventStream.
        workspaceGitMetadataWatchersByWatchedPathsKey.removeAll()
        for task in workspaceGitMetadataCreationWatcherTasksByAncestor.values {
            task.cancel()
        }
        workspaceGitMetadataCreationWatcherTasksByAncestor.removeAll()
        workspaceGitMetadataCreationWatchersByAncestor.removeAll()
        workspaceGitMetadataCreationWatchTargetsByAncestor.removeAll()
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath.removeAll()
        workspaceGitMetadataCreationWatcherAncestorByTargetPath.removeAll()
        workspaceGitMetadataCreationWatcherTargetExistsByPath.removeAll()
        workspaceGitMetadataCreationWatchPathsByProbeKey.removeAll()
        workspaceGitMetadataWatcherSourceDirectoryByKey.removeAll()
        workspaceGitMetadataWatcherKeysBySourceDirectory.removeAll()
        workspaceGitMetadataWatcherWatchedPathsKeyByProbeKey.removeAll()
        workspaceGitMetadataWatcherProbeKeysByWatchedPathsKey.removeAll()
        workspaceGitMetadataWatcherDescriptorRequestsByKey.removeAll()
        workspaceGitMetadataWatcherDescriptorInvalidatedKeys.removeAll()
        workspaceGitSnapshotCacheGenerationByDirectory.removeAll()
    }
}
