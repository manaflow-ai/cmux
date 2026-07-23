import CmuxAgentChat
import CmuxArtifacts
import Foundation

extension AgentChatTranscriptService {
    /// Whether automatic capture needs live transcript completion events without mobile clients.
    var observesTranscriptsForAutomaticArtifactCapture: Bool {
        artifactCaptureCoordinator != nil && isAutomaticArtifactCaptureEnabled()
    }

    /// Starts eager observation with the strongest resolution its active consumer requires.
    func ensureTailerForEagerObservation(for record: AgentChatSessionRecord) {
        let hasSubscribers = hasEventSubscribers()
        guard hasSubscribers || observesTranscriptsForAutomaticArtifactCapture else { return }
        ensureTailer(for: record, usesBoundedResolution: !hasSubscribers)
    }

    /// Reconciles transcript ownership after the Artifacts beta setting changes.
    func reconcileAutomaticArtifactCaptureAvailability() {
        let isEnabled = artifactCaptureCoordinator != nil && isAutomaticArtifactCaptureEnabled()
        guard automaticArtifactCaptureWasEnabled != isEnabled else { return }
        automaticArtifactCaptureWasEnabled = isEnabled

        if isEnabled {
            for record in registry.sessions(workspaceID: nil) where record.state != .ended {
                ensureTailer(for: record, usesBoundedResolution: true)
            }
            return
        }

        let captureTasks = artifactCaptureTasks.values.compactMap(\.task)
        artifactCaptureTasks.removeAll()
        captureTasks.forEach { $0.cancel() }
        guard !hasEventSubscribers() else { return }

        let artifactOnlyTailers = Array(tailers.values)
        tailers.removeAll()
        for tailer in artifactOnlyTailers {
            Task { await tailer.stop() }
        }
    }

    /// Applies one authoritative transcript completion and captures its artifact generation.
    func noteAssistantTurnCompleted(sessionID: String, at timestamp: Date) {
        registry.noteAssistantTurnCompleted(sessionID: sessionID, at: timestamp)
        guard let record = registry.record(sessionID: sessionID) else { return }
        scheduleArtifactCapture(for: record)
    }

    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        guard let artifactCaptureCoordinator, isAutomaticArtifactCaptureEnabled() else { return }
        let resolver = self.resolver
        let artifactIndex = self.artifactIndex
        let isAutomaticArtifactCaptureEnabled = self.isAutomaticArtifactCaptureEnabled
        replaceArtifactCaptureTask(sessionID: record.sessionID) { [weak self] in
            guard !Task.isCancelled, await isAutomaticArtifactCaptureEnabled() else { return }
            guard let transcriptPath = resolver.boundedTranscriptPath(for: record) else { return }
            guard !Task.isCancelled else { return }
            guard let maximumFileBytes = await artifactCaptureCoordinator.maximumTranscriptScanBytes(
                for: record
            ) else {
                return
            }
            guard let snapshot = try? await artifactIndex.snapshot(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                workingDirectory: record.workingDirectory,
                maximumFileBytes: maximumFileBytes
            ) else {
                return
            }
            guard !Task.isCancelled, await isAutomaticArtifactCaptureEnabled() else { return }
            let progress = await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
            guard progress == .needsContinuation,
                  !Task.isCancelled,
                  await isAutomaticArtifactCaptureEnabled() else {
                return
            }
            await self?.enqueueIndexedArtifactCaptureContinuation(
                record: record,
                snapshot: snapshot,
                coordinator: artifactCaptureCoordinator,
                isEnabled: isAutomaticArtifactCaptureEnabled
            )
        }
    }

    /// Reuses an already-indexed gallery snapshot without parsing the transcript again.
    func scheduleIndexedArtifactCapture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) {
        guard let artifactCaptureCoordinator, isAutomaticArtifactCaptureEnabled() else { return }
        let isAutomaticArtifactCaptureEnabled = self.isAutomaticArtifactCaptureEnabled
        replaceArtifactCaptureTask(
            sessionID: record.sessionID,
            operation: indexedArtifactCaptureOperation(
                record: record,
                snapshot: snapshot,
                coordinator: artifactCaptureCoordinator,
                isEnabled: isAutomaticArtifactCaptureEnabled
            )
        )
    }

    private func indexedArtifactCaptureOperation(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot,
        coordinator: AgentArtifactCaptureCoordinator,
        isEnabled: @escaping @MainActor @Sendable () -> Bool
    ) -> @Sendable () async -> Void {
        { [weak self] in
            guard !Task.isCancelled, await isEnabled() else { return }
            let progress = await coordinator.capture(record: record, snapshot: snapshot)
            guard progress == .needsContinuation,
                  !Task.isCancelled,
                  await isEnabled() else {
                return
            }
            await self?.enqueueIndexedArtifactCaptureContinuation(
                record: record,
                snapshot: snapshot,
                coordinator: coordinator,
                isEnabled: isEnabled
            )
        }
    }

    private func enqueueIndexedArtifactCaptureContinuation(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot,
        coordinator: AgentArtifactCaptureCoordinator,
        isEnabled: @escaping @MainActor @Sendable () -> Bool
    ) {
        guard isAutomaticArtifactCaptureEnabled(),
              var active = artifactCaptureTasks[record.sessionID],
              active.pending == nil else {
            return
        }
        active.pending = indexedArtifactCaptureOperation(
            record: record,
            snapshot: snapshot,
            coordinator: coordinator,
            isEnabled: isEnabled
        )
        artifactCaptureTasks[record.sessionID] = active
    }

    func saveArtifact(
        context: ArtifactCaptureContext,
        sourceURL: URL
    ) async throws -> ChatArtifactSaveResult {
        guard let artifactCaptureCoordinator else {
            throw AgentArtifactCaptureSaveError.rejected
        }
        return try await artifactCaptureCoordinator.save(
            context: context,
            sourceURL: sourceURL
        )
    }

    func artifactCaptureContext(for record: AgentChatSessionRecord) async -> ArtifactCaptureContext? {
        guard let artifactCaptureCoordinator else { return nil }
        return await artifactCaptureCoordinator.captureContext(for: record)
    }

    /// Cancels obsolete work and serializes coordinator cleanup before session reuse.
    func removeArtifactCaptureSession(sessionID: String) {
        artifactCaptureTasks.removeValue(forKey: sessionID)?.task?.cancel()
        guard let artifactCaptureCoordinator else { return }
        replaceArtifactCaptureTask(sessionID: sessionID) {
            await artifactCaptureCoordinator.removeSession(sessionID: sessionID)
        }
    }

    private func replaceArtifactCaptureTask(
        sessionID: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        if var active = artifactCaptureTasks[sessionID] {
            active.pending = operation
            artifactCaptureTasks[sessionID] = active
            return
        }
        let token = UUID()
        artifactCaptureTasks[sessionID] = (token: token, task: nil, pending: nil)
        let task = Task.detached(priority: .utility) { [weak self] in
            var current: (@Sendable () async -> Void)? = operation
            while let operation = current, !Task.isCancelled {
                await operation()
                guard !Task.isCancelled else { break }
                current = await self?.takeNextArtifactCaptureOperation(
                    sessionID: sessionID,
                    token: token
                )
            }
            if Task.isCancelled {
                await self?.finishArtifactCaptureTask(sessionID: sessionID, token: token)
            }
        }
        if var entry = artifactCaptureTasks[sessionID], entry.token == token {
            entry.task = task
            artifactCaptureTasks[sessionID] = entry
        } else {
            task.cancel()
        }
    }

    private func finishArtifactCaptureTask(sessionID: String, token: UUID) {
        guard artifactCaptureTasks[sessionID]?.token == token else { return }
        artifactCaptureTasks.removeValue(forKey: sessionID)
    }

    private func takeNextArtifactCaptureOperation(
        sessionID: String,
        token: UUID
    ) -> (@Sendable () async -> Void)? {
        guard var active = artifactCaptureTasks[sessionID], active.token == token else {
            return nil
        }
        guard let pending = active.pending else {
            artifactCaptureTasks.removeValue(forKey: sessionID)
            return nil
        }
        active.pending = nil
        artifactCaptureTasks[sessionID] = active
        return pending
    }
}
