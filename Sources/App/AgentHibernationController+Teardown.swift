import Foundation

extension AgentHibernationRecord {
    var isStillOwnedByOriginalWorkspace: Bool {
        guard let currentPanel = workspace.panels[key.panelId] as? TerminalPanel else { return false }
        return currentPanel === terminalPanel && terminalPanel.workspaceId == key.workspaceId
    }
}

extension AgentHibernationController {
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

            let snapshotOutcomes = await Self.snapshotOutcomes(for: requests)
            var restoreOwnedSnapshotPaths: Set<String> = []
            defer {
                for outcome in snapshotOutcomes.values {
                    guard case .snapshot(let snapshot) = outcome,
                          !restoreOwnedSnapshotPaths.contains(snapshot.snapshotPath) else {
                        continue
                    }
                    try? FileManager.default.removeItem(atPath: snapshot.snapshotPath)
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

                self.terminateScopedProcessesForHibernation(record: record)
                record.workspace.enterAgentHibernation(
                    panelId: record.key.panelId,
                    agent: record.agent,
                    lastActivityAt: Date(timeIntervalSince1970: request.effectiveLastActivityAt)
                )
                guard let snapshot else { continue }
                restoreOwnedSnapshotPaths.insert(snapshot.snapshotPath)
                let processIDs = record.processIDs
                let restoreKey = record.key
                let restoreRequestID = UUID()
                let restoreTask = Task.detached(priority: .utility) {
                    await AgentHibernationTranscriptGuard.runPostTeardownRestoreChecks(
                        snapshot: snapshot,
                        processIDs: processIDs
                    )
                    await MainActor.run {
                        AgentHibernationController.shared.clearPostTeardownRestoreTask(
                            restoreKey,
                            requestID: restoreRequestID
                        )
                    }
                }
                self.storePostTeardownRestoreTask(restoreTask, key: restoreKey, requestID: restoreRequestID)
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
            for (key, agent) in agents {
                group.addTask(priority: .utility) {
                    (key, AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent))
                }
            }
            var outcomes: [AgentHibernationPanelKey: AgentHibernationTranscriptGuard.TeardownSnapshotOutcome] = [:]
            for await (key, outcome) in group {
                outcomes[key] = outcome
            }
            return outcomes
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

    func storePostTeardownRestoreTask(
        _ task: Task<Void, Never>,
        key: AgentHibernationPanelKey,
        requestID: UUID
    ) {
        cancelPostTeardownRestoreTask(key)
        postTeardownRestoreTasksByPanel[key] = PostTeardownRestoreTask(requestID: requestID, task: task)
    }

    func markPostSnapshotValidationPoint() -> UInt64 {
        postSnapshotValidationIndexSequence = postSnapshotValidationIndexSequence &+ 1
        return postSnapshotValidationIndexSequence
    }

    func sharedPostSnapshotValidationIndexTask(minimumStartSequence: UInt64) -> Task<RestorableAgentSessionIndex, Never> {
        if let inFlight = postSnapshotValidationIndexTask,
           inFlight.startSequence >= minimumStartSequence {
            return inFlight.task
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

    func cancelPostTeardownRestoreTask(workspaceId: UUID, panelId: UUID) {
        cancelPostTeardownRestoreTask(AgentHibernationPanelKey(workspaceId: workspaceId, panelId: panelId))
    }

    func cancelPostTeardownRestoreTask(_ key: AgentHibernationPanelKey) {
        postTeardownRestoreTasksByPanel.removeValue(forKey: key)?.task.cancel()
    }

    func cancelPostTeardownRestoreTasks() {
        let tasks = Array(postTeardownRestoreTasksByPanel.values)
        postTeardownRestoreTasksByPanel.removeAll(keepingCapacity: false)
        tasks.forEach { $0.task.cancel() }
    }

    func clearPostTeardownRestoreTask(_ key: AgentHibernationPanelKey, requestID: UUID) {
        guard postTeardownRestoreTasksByPanel[key]?.requestID == requestID else { return }
        postTeardownRestoreTasksByPanel.removeValue(forKey: key)
    }
}
