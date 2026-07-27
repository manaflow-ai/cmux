import Foundation

extension AgentHibernationRecord {
    var isStillOwnedByOriginalWorkspace: Bool {
        guard let currentPanel = workspace.panels[key.panelId] as? TerminalPanel else { return false }
        return currentPanel === terminalPanel && terminalPanel.workspaceId == key.workspaceId
    }
}

extension AgentHibernationController {
    private static let maxConcurrentTeardownSnapshotTasks = 2

    struct ConfirmedTeardownRequest {
        let record: AgentHibernationRecord
        let confirmationFingerprint: String
        let effectiveLastActivityAt: TimeInterval
        let requestID: UUID
        let epoch: UInt64
        let generation: UInt64
    }

    /// Runs the transcript snapshot off the main actor, then resumes teardown on the
    /// main actor only if the pane still qualifies. The snapshot MUST complete before
    /// SIGTERM / pty-close can trigger Claude's interrupted-exit transcript rewrite,
    /// so the teardown is sequenced after it rather than racing it; the re-validation
    /// below covers disable/stop and anything else that changed during the brief I/O hop.
    func beginConfirmedTeardowns(_ requests: [ConfirmedTeardownRequest]) {
        guard !requests.isEmpty else { return }
        Task { @MainActor in
            defer {
                for request in requests {
                    self.clearInFlightTeardown(request.record.key, requestID: request.requestID)
                }
            }

            var snapshotOutcomes = await Self.snapshotOutcomes(for: requests)
            var restoreOwnedSnapshotPaths: Set<String> = []
            defer {
                for outcome in snapshotOutcomes.values {
                    guard case .snapshot(let snapshot) = outcome,
                          !restoreOwnedSnapshotPaths.contains(snapshot.snapshotPath),
                          AgentHibernationTranscriptGuard.liveFileVersionStillMatches(snapshot) else {
                        continue
                    }
                    // A snapshot is disposable only while the live path still
                    // identifies the exact bytes it protected. Any later rewrite
                    // retains the snapshot as a recovery backup.
                    try? FileManager.default.removeItem(atPath: snapshot.snapshotPath)
                }
            }

            // Monitors cancelled by a bulk stop are no longer registered but can
            // still be inside a final restore commit; wait for them so no unawaited
            // writer races this batch. Registered monitors stay armed until this
            // teardown commits — replacement is a handoff, never destroy-then-abort.
            await drainCancelledPostTeardownRestoreTasks()
            let revalidation = await Self.revalidatedSnapshotOutcomes(in: snapshotOutcomes)
            snapshotOutcomes = revalidation.outcomes
            let recordsByKey = Dictionary(
                requests.map { ($0.record.key, $0.record) },
                uniquingKeysWith: { first, _ in first }
            )
            for (key, snapshot) in revalidation.forfeitedSnapshots {
                // The live path changed under the fresh snapshot (e.g. an older
                // monitor restored a stale copy). Arm a restore monitor on the
                // forfeited snapshot so its newest turns stay protected instead of
                // rotting as an orphan; store refuses if a monitor already guards
                // this path, and then that monitor's own snapshot keeps guarding.
                if armPostTeardownRestoreMonitor(
                    snapshot: snapshot,
                    processIDs: recordsByKey[key]?.processIDs ?? [],
                    snapshotDisposal: .retainForRecovery(sessionId: recordsByKey[key]?.agent.sessionId)
                ) {
                    restoreOwnedSnapshotPaths.insert(snapshot.snapshotPath)
                } else {
                    AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
                        snapshot,
                        sessionId: recordsByKey[key]?.agent.sessionId
                    )
                }
            }

            let postSnapshotSequence = markPostSnapshotValidationPoint()
            let postSnapshotIndex = await sharedPostSnapshotValidationIndexTask(
                minimumStartSequence: postSnapshotSequence
            ).value

            for request in requests {
                let record = request.record
                guard let snapshotOutcome = snapshotOutcomes[record.key] else { continue }
                let currentAgent = record.workspace.restorableAgentForHibernation(
                    panelId: record.key.panelId,
                    index: postSnapshotIndex
                )
                let currentLifecycle = postSnapshotLifecycle(for: record, index: postSnapshotIndex)
                let currentEffectiveLastActivityAt = postSnapshotEffectiveLastActivityAt(
                    for: record,
                    index: postSnapshotIndex
                )
                // Re-validate: the pane must still be exactly as confirmed. Any activity,
                // scrollback change, visibility/protection change, hibernation disable,
                // hibernation, or surface loss during the hop aborts; the regular 30s
                // tick will re-arm if still idle.
                guard AgentHibernationTrackingGate.isEnabled(),
                      record.isStillOwnedByOriginalWorkspace,
                      !postSnapshotIndex.hasLiveProcess(workspaceId: record.key.workspaceId, panelId: record.key.panelId),
                      TabManager.restorableAgentSnapshotFingerprint(currentAgent) ==
                          TabManager.restorableAgentSnapshotFingerprint(record.agent),
                      !record.terminalPanel.isAgentHibernated,
                      record.terminalPanel.surface.hasLiveSurface,
                      AppDelegate.shared?.agentHibernationPanelIsProtected(
                          workspace: record.workspace,
                          panelId: record.key.panelId
                      ) == false,
                      currentLifecycle.allowsHibernation,
                      (self.terminalInputByPanel[record.key] ?? 0) <=
                          (self.lifecycleChangeByPanel[record.key] ?? 0),
                      self.teardownValidationGeneration == request.generation,
                      (self.teardownValidationEpochByPanel[record.key] ?? 0) == request.epoch,
                      let currentFingerprint = self.hibernationFingerprint(for: record),
                      currentFingerprint == request.confirmationFingerprint,
                      currentEffectiveLastActivityAt <= request.effectiveLastActivityAt else {
                    continue
                }

                let snapshot: AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot?
                switch snapshotOutcome {
                case .snapshot(let value):
                    snapshot = value
                case .nothingToProtect:
                    snapshot = nil
                case .unableToProtect:
                    // Forfeit hibernation rather than risk issue #6565 transcript loss.
                    self.unableToProtectByPanel[record.key] = UnableToProtectMarker(
                        fingerprint: request.confirmationFingerprint,
                        lastActivityAt: request.effectiveLastActivityAt,
                        retryAfter: Date().timeIntervalSince1970 + Self.unableToProtectRetrySeconds
                    )
                    continue
                }

                if let snapshot {
                    // An armed monitor for this transcript (a prior hibernation's,
                    // or one stored earlier in this batch) hands off here: quiesce
                    // it only now that this request is otherwise committed, and
                    // re-check the path version. Nothing may suspend between the
                    // check and SIGTERM, or a rewrite can invalidate the snapshot.
                    await cancelPostTeardownRestoreTaskForReplacement(
                        transcriptPath: snapshot.transcriptPath
                    )
                    guard AgentHibernationTranscriptGuard.liveFileVersionStillMatches(snapshot) else {
                        self.unableToProtectByPanel[record.key] = UnableToProtectMarker(
                            fingerprint: request.confirmationFingerprint,
                            lastActivityAt: request.effectiveLastActivityAt,
                            retryAfter: Date().timeIntervalSince1970 + Self.unableToProtectRetrySeconds
                        )
                        // The quiesce above disarmed the path's previous monitor, so
                        // forfeiting must re-arm protection with the fresh snapshot;
                        // its restore checks fail closed if the live file has turns.
                        if self.armPostTeardownRestoreMonitor(
                            snapshot: snapshot,
                            processIDs: record.processIDs,
                            snapshotDisposal: .retainForRecovery(sessionId: record.agent.sessionId)
                        ) {
                            restoreOwnedSnapshotPaths.insert(snapshot.snapshotPath)
                        } else {
                            AgentHibernationTranscriptGuard.retainSnapshotForRecovery(
                                snapshot,
                                sessionId: record.agent.sessionId
                            )
                        }
                        continue
                    }
                }
                self.terminateScopedProcessesForHibernation(record: record)
                record.workspace.enterAgentHibernation(
                    panelId: record.key.panelId,
                    agent: record.agent,
                    lastActivityAt: Date(timeIntervalSince1970: request.effectiveLastActivityAt)
                )
                guard let snapshot else { continue }
                if self.armPostTeardownRestoreMonitor(snapshot: snapshot, processIDs: record.processIDs) {
                    restoreOwnedSnapshotPaths.insert(snapshot.snapshotPath)
                }
            }
        }
    }

    private static func snapshotOutcomes(
        for requests: [ConfirmedTeardownRequest]
    ) async -> [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome] {
        let agents = requests.map { ($0.record.key, $0.record.agent) }
        return await withTaskGroup(
            of: (AgentHibernationPanelKey, AgentHibernationTranscriptGuard.TeardownSnapshotOutcome).self,
            returning: [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome].self
        ) { group in
            var nextAgentIndex = 0
            let initialTaskCount = min(Self.maxConcurrentTeardownSnapshotTasks, agents.count)
            for _ in 0..<initialTaskCount {
                let (key, agent) = agents[nextAgentIndex]
                nextAgentIndex += 1
                group.addTask(priority: .utility) {
                    (key, AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent, panelKey: key))
                }
            }
            var outcomes: [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome] = [:]
            while let (key, outcome) = await group.next() {
                outcomes[key] = outcome
                guard nextAgentIndex < agents.count else { continue }
                let (nextKey, nextAgent) = agents[nextAgentIndex]
                nextAgentIndex += 1
                group.addTask(priority: .utility) {
                    (nextKey, AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: nextAgent, panelKey: nextKey))
                }
            }
            return outcomes
        }
    }

    struct SnapshotRevalidation {
        var outcomes: [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome]
        var forfeitedSnapshots: [(AgentHibernationPanelKey, AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot)]
    }

    private static func revalidatedSnapshotOutcomes(
        in outcomes: [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome]
    ) async -> SnapshotRevalidation {
        let snapshots = outcomes.compactMap { key, outcome -> (AgentHibernationPanelKey, AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot)? in
            guard case .snapshot(let snapshot) = outcome else { return nil }
            return (key, snapshot)
        }
        let originalSnapshotsByKey = Dictionary(snapshots, uniquingKeysWith: { first, _ in first })
        return await withTaskGroup(
            of: (AgentHibernationPanelKey, AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot?).self
        ) { group in
            var nextSnapshotIndex = 0
            let initialTaskCount = min(Self.maxConcurrentTeardownSnapshotTasks, snapshots.count)
            for _ in 0..<initialTaskCount {
                let (key, snapshot) = snapshots[nextSnapshotIndex]
                nextSnapshotIndex += 1
                group.addTask(priority: .utility) {
                    (key, AgentHibernationTranscriptGuard.snapshotStillMatchesLive(snapshot))
                }
            }
            var revalidation = SnapshotRevalidation(outcomes: outcomes, forfeitedSnapshots: [])
            while let (key, revalidatedSnapshot) = await group.next() {
                if let revalidatedSnapshot {
                    revalidation.outcomes[key] = .snapshot(revalidatedSnapshot)
                } else {
                    // A stale older monitor or live Claude write changed the path.
                    // Forfeit this hibernation and report the populated snapshot so
                    // the caller can arm a protective monitor on it.
                    revalidation.outcomes[key] = .unableToProtect
                    if let originalSnapshot = originalSnapshotsByKey[key] {
                        revalidation.forfeitedSnapshots.append((key, originalSnapshot))
                    }
                }
                guard nextSnapshotIndex < snapshots.count else { continue }
                let (nextKey, nextSnapshot) = snapshots[nextSnapshotIndex]
                nextSnapshotIndex += 1
                group.addTask(priority: .utility) {
                    (nextKey, AgentHibernationTranscriptGuard.snapshotStillMatchesLive(nextSnapshot))
                }
            }
            return revalidation
        }
    }

    func postSnapshotLifecycle(
        for record: AgentHibernationRecord,
        index: RestorableAgentSessionIndex
    ) -> AgentHibernationLifecycleState {
        record.workspace.agentHibernationLifecycleState(
            panelId: record.key.panelId,
            fallback: index.lifecycle(workspaceId: record.key.workspaceId, panelId: record.key.panelId)
        )
    }

    func postSnapshotEffectiveLastActivityAt(
        for record: AgentHibernationRecord,
        index: RestorableAgentSessionIndex
    ) -> TimeInterval {
        let indexActivity = index.updatedAt(workspaceId: record.key.workspaceId, panelId: record.key.panelId) ?? 0
        let localActivity = activityByPanel[record.key] ?? 0
        let createdAt = record.terminalPanel.surface.debugRuntimeSurfaceCreatedAt()?.timeIntervalSince1970
            ?? record.terminalPanel.surface.debugCreatedAt().timeIntervalSince1970
        return max(indexActivity, localActivity, createdAt)
    }

    /// Builds and registers a restore monitor guarding the snapshot's transcript
    /// path. Returns false without any restore side effects when another monitor
    /// already guards that path — the existing monitor keeps its protection.
    @discardableResult
    func armPostTeardownRestoreMonitor(
        snapshot: AgentHibernationTranscriptGuard.TeardownTranscriptSnapshot,
        processIDs: Set<Int>,
        snapshotDisposal: AgentHibernationTranscriptGuard.PostTeardownSnapshotDisposal = .deleteWhenSafe
    ) -> Bool {
        let transcriptPath = snapshot.transcriptPath
        let requestID = UUID()
        let cancellationState = PostTeardownRestoreCancellationState()
        let task = Task.detached(priority: .utility) {
            await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                snapshot: snapshot,
                processIDs: processIDs,
                snapshotDisposal: snapshotDisposal,
                shouldContinue: {
                    await MainActor.run {
                        AgentHibernationController.shared.postTeardownRestoreTaskIsCurrent(
                            transcriptPath: transcriptPath,
                            requestID: requestID
                        )
                    }
                },
                shouldRestoreOnCancellation: {
                    await MainActor.run {
                        cancellationState.restoresSnapshotOnCancellation
                    }
                }
            )
            await MainActor.run {
                AgentHibernationController.shared.clearPostTeardownRestoreTask(
                    transcriptPath: transcriptPath,
                    requestID: requestID
                )
            }
        }
        return storePostTeardownRestoreTask(
            task,
            transcriptPath: transcriptPath,
            requestID: requestID,
            cancellationState: cancellationState
        )
    }

    @discardableResult
    func storePostTeardownRestoreTask(
        _ task: Task<Void, Never>,
        transcriptPath: String,
        requestID: UUID,
        cancellationState: PostTeardownRestoreCancellationState
    ) -> Bool {
        let key = Self.postTeardownRestoreTaskKey(transcriptPath: transcriptPath)
        guard postTeardownRestoreTasksByTranscriptPath[key] == nil else {
            cancellationState.restoresSnapshotOnCancellation = false
            task.cancel()
            return false
        }
        postTeardownRestoreTasksByTranscriptPath[key] = PostTeardownRestoreTask(
            requestID: requestID,
            cancellationState: cancellationState,
            task: task
        )
        return true
    }

    func markPostSnapshotValidationPoint() -> UInt64 {
        postSnapshotValidationIndexSequence = postSnapshotValidationIndexSequence &+ 1
        return postSnapshotValidationIndexSequence
    }

    func sharedPostSnapshotValidationIndexTask(minimumStartSequence: UInt64) -> Task<RestorableAgentSessionIndex, Never> {
        if let inFlight = postSnapshotValidationIndexTask {
            if inFlight.startSequence >= minimumStartSequence {
                return inFlight.task
            }
            inFlight.task.cancel()
        }
        let requestID = UUID()
        let startSequence = postSnapshotValidationIndexSequence
        let task = Task.detached(priority: .utility) {
            await RestorableAgentSessionIndex.loadIncludingProcessDetectedSnapshots()
        }
        postSnapshotValidationIndexTask = PostSnapshotValidationIndexTask(
            requestID: requestID,
            startSequence: startSequence,
            task: task
        )
        Task { @MainActor in
            _ = await task.value
            guard self.postSnapshotValidationIndexTask?.requestID == requestID else { return }
            self.postSnapshotValidationIndexTask = nil
        }
        return task
    }

    func cancelPostTeardownRestoreTaskForReplacement(transcriptPath: String) async {
        let key = Self.postTeardownRestoreTaskKey(transcriptPath: transcriptPath)
        guard let entry = postTeardownRestoreTasksByTranscriptPath.removeValue(forKey: key) else { return }
        entry.cancellationState.restoresSnapshotOnCancellation = false
        entry.task.cancel()
        await entry.task.value
    }

    func cancelPostTeardownRestoreTasks() {
        let entries = Array(postTeardownRestoreTasksByTranscriptPath.values)
        postTeardownRestoreTasksByTranscriptPath.removeAll(keepingCapacity: false)
        guard !entries.isEmpty else { return }
        // Cancellation keeps the final protective restore enabled (stop/disable
        // paths want one last check). The drain task makes those unregistered
        // in-flight restores awaitable so a later teardown cannot race them.
        entries.forEach { $0.task.cancel() }
        let previousDrain = postTeardownRestoreDrainTask
        postTeardownRestoreDrainTask = Task.detached(priority: .utility) {
            await previousDrain?.value
            for entry in entries {
                await entry.task.value
            }
        }
    }

    func drainCancelledPostTeardownRestoreTasks() async {
        await postTeardownRestoreDrainTask?.value
    }

    func postTeardownRestoreTaskIsCurrent(transcriptPath: String, requestID: UUID) -> Bool {
        let key = Self.postTeardownRestoreTaskKey(transcriptPath: transcriptPath)
        return postTeardownRestoreTasksByTranscriptPath[key]?.requestID == requestID
    }

    func clearPostTeardownRestoreTask(transcriptPath: String, requestID: UUID) {
        let key = Self.postTeardownRestoreTaskKey(transcriptPath: transcriptPath)
        guard postTeardownRestoreTasksByTranscriptPath[key]?.requestID == requestID else { return }
        postTeardownRestoreTasksByTranscriptPath.removeValue(forKey: key)
    }

    static func postTeardownRestoreTaskKey(transcriptPath: String) -> String {
        // Resolve symlinks, not just path text: hook-recorded and derived
        // transcript paths can alias one physical file, and aliased keys would
        // let two monitors guard (and race on) the same inode.
        (transcriptPath as NSString).resolvingSymlinksInPath
    }
}
