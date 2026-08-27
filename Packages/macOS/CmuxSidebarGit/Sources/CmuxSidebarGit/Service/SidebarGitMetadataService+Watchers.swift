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

        // Non-forced calls are content-only refreshes. HEAD/branch changes,
        // metadata events, and creation-watch races all force a descriptor
        // rebuild so conditional config paths cannot be skipped by this reuse.
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
        var targetNeedsImmediateRefresh = false
        for path in normalizedPaths {
            let accepted: Bool
            if previousPaths.contains(path) {
                accepted = refreshWorkspaceGitMetadataCreationWatchTarget(
                    path,
                    for: key,
                    targetNeedsImmediateRefresh: &targetNeedsImmediateRefresh
                )
            } else {
                accepted = addWorkspaceGitMetadataCreationWatchTarget(
                    path,
                    for: key,
                    targetNeedsImmediateRefresh: &targetNeedsImmediateRefresh
                )
            }
            if accepted {
                acceptedPaths.insert(path)
            }
        }
        workspaceGitMetadataCreationWatchPathsByProbeKey[key] = acceptedPaths
        if targetNeedsImmediateRefresh {
            recordWorkspaceGitMetadataFilesystemEvent(for: key)
            scheduleWorkspaceGitMetadataRefreshIfPossible(
                workspaceId: key.workspaceId,
                panelId: key.panelId,
                reason: "configAlreadyCreated"
            )
            if let directory = workspaceGitMetadataWatcherSourceDirectoryByKey[key] {
                updateWorkspaceGitMetadataWatcher(
                    for: key,
                    directory: directory,
                    forceDescriptorRefresh: true
                )
            }
        }
    }

    private func refreshWorkspaceGitMetadataCreationWatchTarget(
        _ path: String,
        for key: WorkspaceGitProbeKey,
        targetNeedsImmediateRefresh: inout Bool
    ) -> Bool {
        guard workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] != nil else {
            return addWorkspaceGitMetadataCreationWatchTarget(
                path,
                for: key,
                targetNeedsImmediateRefresh: &targetNeedsImmediateRefresh
            )
        }
        let newAncestor = nearestExistingDirectory(for: path)
        guard creationWatchAncestorIsSafe(newAncestor, for: key) else {
            removeWorkspaceGitMetadataCreationWatchTarget(path, for: key)
            return false
        }
        if workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] != newAncestor {
            let oldAncestor = workspaceGitMetadataCreationWatcherAncestorByTargetPath[path]!
            migrateWorkspaceGitMetadataCreationWatchTarget(
                path,
                from: oldAncestor,
                to: newAncestor
            )
            targetNeedsImmediateRefresh = true
        }
        let newLogicalParent = logicalSymlinkParent(for: path).flatMap {
            creationWatchAncestorIsSafe($0, for: key) ? $0 : nil
        }
        if updateWorkspaceGitMetadataLogicalParent(path, to: newLogicalParent) {
            targetNeedsImmediateRefresh = true
        }
        let newSignature = logicalSymlinkSignature(for: path)
        let oldSignature = workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath[path]
            ?? nil
        if oldSignature != newSignature {
            workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath[path] = newSignature
            targetNeedsImmediateRefresh = true
        }
        let targetExists = creationWatchFileManager.fileExists(atPath: path)
        if workspaceGitMetadataCreationWatcherTargetExistsByPath[path] != targetExists {
            workspaceGitMetadataCreationWatcherTargetExistsByPath[path] = targetExists
            targetNeedsImmediateRefresh = true
        }
        let ancestors = Set([
            workspaceGitMetadataCreationWatcherAncestorByTargetPath[path],
            workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[path],
        ].compactMap { $0 })
        for ancestor in ancestors {
            ensureWorkspaceGitMetadataCreationWatcher(for: ancestor)
        }
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[path, default: []].insert(key)
        return true
    }

    private func stopWorkspaceGitMetadataCreationWatchers(for key: WorkspaceGitProbeKey) {
        let paths = workspaceGitMetadataCreationWatchPathsByProbeKey.removeValue(forKey: key) ?? []
        for path in paths {
            removeWorkspaceGitMetadataCreationWatchTarget(path, for: key)
        }
    }

    private func addWorkspaceGitMetadataCreationWatchTarget(
        _ path: String,
        for key: WorkspaceGitProbeKey,
        targetNeedsImmediateRefresh: inout Bool
    ) -> Bool {
        let ancestor = nearestExistingDirectory(for: path)
        guard creationWatchAncestorIsSafe(ancestor, for: key) else { return false }
        let targetIsNew = workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] == nil
        if targetIsNew {
            let targetCount = workspaceGitMetadataCreationWatcherAncestorByTargetPath.count
            guard targetCount < 512 else { return false }
            let logicalParent = logicalSymlinkParent(for: path).flatMap {
                creationWatchAncestorIsSafe($0, for: key) ? $0 : nil
            }
            let ancestors = Set([ancestor, logicalParent].compactMap { $0 })
            let newAncestors = ancestors.filter {
                workspaceGitMetadataCreationWatchTargetsByAncestor[$0] == nil
            }
            guard workspaceGitMetadataCreationWatchersByAncestor.count + newAncestors.count <= 128 else {
                return false
            }
            workspaceGitMetadataCreationWatcherAncestorByTargetPath[path] = ancestor
            if let logicalParent {
                workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[path] = logicalParent
            }
            workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath[path] =
                logicalSymlinkSignature(for: path)
            let targetExists = creationWatchFileManager.fileExists(atPath: path)
            workspaceGitMetadataCreationWatcherTargetExistsByPath[path] = targetExists
            targetNeedsImmediateRefresh = targetNeedsImmediateRefresh || targetExists
            for watchAncestor in ancestors {
                workspaceGitMetadataCreationWatchTargetsByAncestor[watchAncestor, default: []]
                    .insert(path)
            }
        } else if workspaceGitMetadataCreationWatcherTargetExistsByPath[path] == true {
            targetNeedsImmediateRefresh = true
        }
        workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[path, default: []].insert(key)
        let watchAncestors = Set([
            workspaceGitMetadataCreationWatcherAncestorByTargetPath[path],
            workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[path],
        ].compactMap { $0 })
        for watchAncestor in watchAncestors {
            ensureWorkspaceGitMetadataCreationWatcher(for: watchAncestor)
        }
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
        let ancestors = Set([
            workspaceGitMetadataCreationWatcherAncestorByTargetPath.removeValue(forKey: path),
            workspaceGitMetadataCreationWatcherLogicalParentByTargetPath.removeValue(forKey: path),
        ].compactMap { $0 })
        workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath.removeValue(forKey: path)
        for ancestor in ancestors {
            workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor]?.remove(path)
            if workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor]?.isEmpty == true {
                workspaceGitMetadataCreationWatchTargetsByAncestor.removeValue(forKey: ancestor)
                workspaceGitMetadataCreationWatcherTasksByAncestor.removeValue(forKey: ancestor)?.cancel()
                workspaceGitMetadataCreationWatchersByAncestor.removeValue(forKey: ancestor)
            }
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
                var changedTargets: Set<String> = []
                for target in targets {
                    let isResolvedAncestor =
                        self.workspaceGitMetadataCreationWatcherAncestorByTargetPath[target]
                        == ancestor
                    let isLogicalAncestor =
                        self.workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[target]
                        == ancestor
                    guard isResolvedAncestor || isLogicalAncestor,
                          let snapshot = snapshots[target] else {
                        continue
                    }
                    let closerAncestor = snapshot.nearestExistingDirectory
                    if isResolvedAncestor, closerAncestor != ancestor, closerAncestor != "/" {
                        self.migrateWorkspaceGitMetadataCreationWatchTarget(
                            target,
                            from: ancestor,
                            to: closerAncestor
                        )
                        changedTargets.insert(target)
                    }
                    if isLogicalAncestor {
                        if self.updateWorkspaceGitMetadataLogicalParent(
                            target,
                            to: snapshot.logicalSymlinkParent
                        ) {
                            changedTargets.insert(target)
                        }
                        if self.workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath[target]
                            != snapshot.logicalSymlinkSignature {
                            self.workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath[target] =
                                snapshot.logicalSymlinkSignature
                            changedTargets.insert(target)
                        }
                    }
                    if self.workspaceGitMetadataCreationWatcherTargetExistsByPath[target]
                        != snapshot.exists {
                        self.workspaceGitMetadataCreationWatcherTargetExistsByPath[target] =
                            snapshot.exists
                        changedTargets.insert(target)
                    }
                }
                guard !changedTargets.isEmpty else { continue }
                let keySet = changedTargets.reduce(into: Set<WorkspaceGitProbeKey>()) { result, target in
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
        guard creationWatchAncestorIsSafe(ancestor, forTarget: target) else {
            return
        }
        let removesPreviousWatcher =
            workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.count == 1
        guard workspaceGitMetadataCreationWatcherAncestorByTargetPath[target] == previousAncestor,
              workspaceGitMetadataCreationWatchTargetsByAncestor[ancestor] != nil
                || workspaceGitMetadataCreationWatchersByAncestor.count < 128
                || removesPreviousWatcher else {
            return
        }
        let previousAncestorIsLogical =
            workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[target]
            == previousAncestor
        if !previousAncestorIsLogical {
            workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.remove(target)
        }
        if !previousAncestorIsLogical,
           workspaceGitMetadataCreationWatchTargetsByAncestor[previousAncestor]?.isEmpty == true {
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

    @discardableResult
    private func updateWorkspaceGitMetadataLogicalParent(
        _ target: String,
        to newParent: String?
    ) -> Bool {
        let oldParent = workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[target]
        guard oldParent != newParent else { return false }
        if let newParent, newParent != oldParent, newParent != "/" {
            guard creationWatchAncestorIsSafe(newParent, forTarget: target) else {
                return false
            }
            let isNewAncestor = workspaceGitMetadataCreationWatchTargetsByAncestor[newParent] == nil
            guard !isNewAncestor || workspaceGitMetadataCreationWatchersByAncestor.count < 128 else {
                return false
            }
        }
        if let oldParent {
            let primaryParent = workspaceGitMetadataCreationWatcherAncestorByTargetPath[target]
            if primaryParent != oldParent {
                workspaceGitMetadataCreationWatchTargetsByAncestor[oldParent]?.remove(target)
            }
            if primaryParent != oldParent,
               workspaceGitMetadataCreationWatchTargetsByAncestor[oldParent]?.isEmpty == true {
                workspaceGitMetadataCreationWatchTargetsByAncestor.removeValue(forKey: oldParent)
                workspaceGitMetadataCreationWatcherTasksByAncestor
                    .removeValue(forKey: oldParent)?
                    .cancel()
                workspaceGitMetadataCreationWatchersByAncestor.removeValue(forKey: oldParent)
            }
        }
        guard let newParent, newParent != "/" else {
            workspaceGitMetadataCreationWatcherLogicalParentByTargetPath.removeValue(forKey: target)
            return true
        }
        workspaceGitMetadataCreationWatcherLogicalParentByTargetPath[target] = newParent
        workspaceGitMetadataCreationWatchTargetsByAncestor[newParent, default: []].insert(target)
        ensureWorkspaceGitMetadataCreationWatcher(for: newParent)
        return true
    }

    @concurrent
    nonisolated private func creationTargetSnapshots(
        for paths: [String]
    ) async -> [String: WorkspaceGitMetadataCreationTargetSnapshot] {
        paths.reduce(into: [String: WorkspaceGitMetadataCreationTargetSnapshot]()) { result, path in
            result[path] = WorkspaceGitMetadataCreationTargetSnapshot(
                exists: creationWatchFileManager.fileExists(atPath: path),
                nearestExistingDirectory: nearestExistingDirectory(for: path),
                logicalSymlinkParent: logicalSymlinkParent(for: path),
                logicalSymlinkSignature: logicalSymlinkSignature(for: path)
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

    nonisolated private func logicalSymlinkParent(for path: String) -> String? {
        var current = URL(fileURLWithPath: "/")
        for component in path.split(separator: "/") {
            let next = current.appendingPathComponent(String(component))
            if (try? creationWatchFileManager.destinationOfSymbolicLink(atPath: next.path)) != nil {
                let parent = current.standardizedFileURL.path
                return parent == "/" ? nil : parent
            }
            current = next
        }
        return nil
    }

    nonisolated private func logicalSymlinkSignature(for path: String) -> String? {
        var current = URL(fileURLWithPath: "/")
        var components: [String] = []
        for component in path.split(separator: "/") {
            let next = current.appendingPathComponent(String(component))
            if let destination = try? creationWatchFileManager.destinationOfSymbolicLink(
                atPath: next.path
            ) {
                components.append("\(next.path)=\(destination)")
            }
            current = next
        }
        return components.isEmpty ? nil : components.joined(separator: "|")
    }

    private func creationWatchAncestorIsSafe(
        _ ancestor: String,
        for key: WorkspaceGitProbeKey
    ) -> Bool {
        let resolvedAncestor = URL(fileURLWithPath: ancestor)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard resolvedAncestor != "/" else { return false }
        let home = URL(fileURLWithPath: creationWatchHomeDirectory)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        if isSameOrInside(resolvedAncestor, root: home) {
            return true
        }
        guard let workspaceRoot = workspaceGitTrackedDirectoryByKey[key] else {
            return false
        }
        let resolvedWorkspaceRoot = URL(fileURLWithPath: workspaceRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return isSameOrInside(resolvedAncestor, root: resolvedWorkspaceRoot)
    }

    private func creationWatchAncestorIsSafe(
        _ ancestor: String,
        forTarget target: String
    ) -> Bool {
        let keys = workspaceGitMetadataCreationWatcherProbeKeysByTargetPath[target] ?? []
        return keys.contains { creationWatchAncestorIsSafe(ancestor, for: $0) }
    }

    private func isSameOrInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
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
        workspaceGitMetadataCreationWatcherLogicalParentByTargetPath.removeAll()
        workspaceGitMetadataCreationWatcherLogicalSignatureByTargetPath.removeAll()
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
