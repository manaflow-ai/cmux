import Foundation

extension AgentHibernationRecord {
    var isStillOwnedByOriginalWorkspace: Bool {
        guard let currentPanel = workspace.panels[key.panelId] as? TerminalPanel else { return false }
        return currentPanel === terminalPanel && terminalPanel.workspaceId == key.workspaceId
    }
}

extension AgentHibernationController {
    /// Runs the transcript snapshot off the main actor, then resumes teardown on the
    /// main actor only if the pane still qualifies. The snapshot MUST complete before
    /// SIGTERM / pty-close can trigger Claude's interrupted-exit transcript rewrite,
    /// so the teardown is sequenced after it rather than racing it; the re-validation
    /// below covers disable/stop and anything else that changed during the brief I/O hop.
    func beginConfirmedTeardown(
        record: AgentHibernationRecord,
        confirmationFingerprint: String,
        effectiveLastActivityAt: TimeInterval,
        requestID: UUID
    ) {
        let agent = record.agent
        let epoch = teardownValidationEpochByPanel[record.key] ?? 0
        let generation = teardownValidationGeneration
        Task { @MainActor in
            defer { self.clearInFlightTeardown(record.key, requestID: requestID) }
            let snapshotOutcome = await Task.detached(priority: .utility) {
                AgentHibernationTranscriptGuard.snapshotBeforeTeardown(agent: agent)
            }.value
            var restoreTaskOwnsSnapshot = false
            defer {
                if !restoreTaskOwnsSnapshot,
                   case .snapshot(let snapshot) = snapshotOutcome {
                    try? FileManager.default.removeItem(atPath: snapshot.snapshotPath)
                }
            }
            let postSnapshotSequence = markPostSnapshotValidationPoint()
            let postSnapshotIndex = await sharedPostSnapshotValidationIndexTask(
                minimumStartSequence: postSnapshotSequence
            ).value
            let currentAgent = record.workspace.restorableAgentForHibernation(
                panelId: record.key.panelId,
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
                  record.workspace.agentHibernationLifecycleState(
                      panelId: record.key.panelId,
                      fallback: record.lifecycle
                  ).allowsHibernation,
                  (self.terminalInputByPanel[record.key] ?? 0) <=
                      (self.lifecycleChangeByPanel[record.key] ?? 0),
                  self.teardownValidationGeneration == generation,
                  (self.teardownValidationEpochByPanel[record.key] ?? 0) == epoch,
                  let currentFingerprint = self.hibernationFingerprint(for: record),
                  currentFingerprint == confirmationFingerprint,
                  (self.activityByPanel[record.key] ?? 0) <= effectiveLastActivityAt else {
                return
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
                    fingerprint: confirmationFingerprint,
                    lastActivityAt: effectiveLastActivityAt,
                    retryAfter: Date().timeIntervalSince1970 + Self.unableToProtectRetrySeconds
                )
                return
            }

            self.terminateScopedProcessesForHibernation(record: record)
            record.workspace.enterAgentHibernation(
                panelId: record.key.panelId,
                agent: record.agent,
                lastActivityAt: Date(timeIntervalSince1970: effectiveLastActivityAt)
            )
            guard let snapshot else { return }
            restoreTaskOwnsSnapshot = true
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
