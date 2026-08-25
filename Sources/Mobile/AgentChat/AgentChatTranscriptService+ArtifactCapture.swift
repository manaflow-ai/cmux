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
        ensureTailer(
            for: record,
            ownership: hasSubscribers ? .mobileSubscriber : .automaticArtifactCapture,
            resolvePath: { resolver.boundedTranscriptPath(for: record) }
        )
    }

    /// Reconciles transcript ownership after the Artifacts beta setting changes.
    func reconcileAutomaticArtifactCaptureAvailability() {
        let isEnabled = artifactCaptureCoordinator != nil && isAutomaticArtifactCaptureEnabled()
        guard automaticArtifactCaptureWasEnabled != isEnabled else {
            reconcileTranscriptTailerOwnership()
            return
        }
        automaticArtifactCaptureWasEnabled = isEnabled

        if isEnabled {
            for record in registry.sessions(workspaceID: nil) where record.state != .ended {
                ensureTailerForEagerObservation(for: record)
            }
            reconcileTranscriptTailerOwnership()
            return
        }

        let captureTasks = artifactCaptureTasks.values.compactMap(\.task)
        artifactCaptureTasks.removeAll()
        captureTasks.forEach { $0.cancel() }
        artifactCaptureDebounceTasks.values.forEach { $0.task.cancel() }
        artifactCaptureDebounceTasks.removeAll()
        reconcileTranscriptTailerOwnership()
    }

    /// Records the strongest current consumer for a tailer and refreshes its
    /// artifact-only recency when automatic capture owns it.
    func noteTailerUse(
        sessionID: String,
        ownership: AgentChatTranscriptTailerOwnership
    ) {
        guard tailers[sessionID] != nil else { return }
        switch ownership {
        case .mobileSubscriber:
            tailerOwnership[sessionID] = .mobileSubscriber
            artifactTailerLastUse.removeValue(forKey: sessionID)
        case .automaticArtifactCapture:
            guard tailerOwnership[sessionID] != .mobileSubscriber else { return }
            tailerOwnership[sessionID] = .automaticArtifactCapture
            artifactTailerUseCounter &+= 1
            artifactTailerLastUse[sessionID] = artifactTailerUseCounter
        }
    }

    /// Stops and forgets one tailer, including its ownership and LRU entry.
    func removeTailer(sessionID: String) {
        tailerOwnership.removeValue(forKey: sessionID)
        artifactTailerLastUse.removeValue(forKey: sessionID)
        guard let tailer = tailers.removeValue(forKey: sessionID) else { return }
        Task { await tailer.stop() }
    }

    /// Evicts the least recently used artifact-only tailers until the bounded
    /// policy is satisfied. A newly requested session is protected so a full
    /// cap never immediately evicts the work that caused the insertion.
    func enforceArtifactTailerLimit(protectedSessionID: String? = nil) {
        while artifactTailerLastUse.count > Self.maxArtifactOnlyTailers {
            guard let victim = artifactTailerLastUse
                .filter({ $0.key != protectedSessionID })
                .min(by: { lhs, rhs in
                    if lhs.value == rhs.value { return lhs.key < rhs.key }
                    return lhs.value < rhs.value
                })?.key else {
                return
            }
            removeTailer(sessionID: victim)
        }
    }

    /// Reconciles tailer ownership when subscriber demand changes outside a
    /// hook event. This releases subscriber-only state when neither consumer
    /// needs it and demotes it into the bounded artifact pool when capture is
    /// still enabled.
    func reconcileTranscriptTailerOwnership() {
        let hasSubscribers = hasEventSubscribers()
        if hasSubscribers {
            for sessionID in tailers.keys {
                guard let record = registry.record(sessionID: sessionID), record.state != .ended else {
                    continue
                }
                noteTailerUse(sessionID: sessionID, ownership: .mobileSubscriber)
            }
            return
        }

        if observesTranscriptsForAutomaticArtifactCapture {
            for sessionID in tailers.keys {
                noteTailerUse(sessionID: sessionID, ownership: .automaticArtifactCapture)
            }
            enforceArtifactTailerLimit()
        } else {
            for sessionID in Array(tailers.keys) {
                removeTailer(sessionID: sessionID)
            }
        }
    }

    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        cancelDebouncedArtifactCapture(sessionID: record.sessionID)
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
            await self?.scheduleIndexedArtifactCaptureContinuation(
                progress: progress,
                record: record,
                snapshot: snapshot,
                coordinator: artifactCaptureCoordinator,
                isEnabled: isAutomaticArtifactCaptureEnabled,
                contentionRetryAttempt: 0
            )
        }
    }

    /// Coalesces streamed prose batches until the transcript has been quiet.
    ///
    /// Transcript tailers emit each streamed prose line independently, but a
    /// full artifact-index snapshot is bounded by bytes rather than lines.
    /// Waiting for a short quiet period keeps sustained output from repeatedly
    /// reparsing the same large transcript while still capturing turns that do
    /// not produce a Stop hook.
    func scheduleDebouncedArtifactCapture(for record: AgentChatSessionRecord) {
        guard artifactCaptureCoordinator != nil,
              isAutomaticArtifactCaptureEnabled() else {
            return
        }
        let sessionID = record.sessionID
        artifactCaptureDebounceTasks[sessionID]?.task.cancel()
        let token = UUID()
        let clock = artifactCaptureDebounceClock
        let task = Task { [weak self] in
            do {
                try await clock.sleep(for: Self.artifactCaptureDebounceDelay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            guard self.artifactCaptureDebounceTasks[sessionID]?.token == token else {
                return
            }
            self.artifactCaptureDebounceTasks.removeValue(forKey: sessionID)
            guard let currentRecord = self.registry.record(sessionID: sessionID),
                  currentRecord.state != .ended,
                  self.isAutomaticArtifactCaptureEnabled() else {
                return
            }
            self.scheduleArtifactCapture(for: currentRecord)
        }
        artifactCaptureDebounceTasks[sessionID] = (token: token, task: task)
    }

    /// Cancels a pending prose debounce when an immediate lifecycle event wins.
    func cancelDebouncedArtifactCapture(sessionID: String) {
        artifactCaptureDebounceTasks.removeValue(forKey: sessionID)?.task.cancel()
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
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        contentionRetryAttempt: Int = 0
    ) -> @Sendable () async -> Void {
        { [weak self] in
            guard !Task.isCancelled, await isEnabled() else { return }
            let progress = await coordinator.capture(record: record, snapshot: snapshot)
            await self?.scheduleIndexedArtifactCaptureContinuation(
                progress: progress,
                record: record,
                snapshot: snapshot,
                coordinator: coordinator,
                isEnabled: isEnabled,
                contentionRetryAttempt: contentionRetryAttempt
            )
        }
    }

    private func scheduleIndexedArtifactCaptureContinuation(
        progress: AgentArtifactCaptureProgress,
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot,
        coordinator: AgentArtifactCaptureCoordinator,
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        contentionRetryAttempt: Int
    ) async {
        guard !Task.isCancelled, isEnabled() else { return }
        let nextContentionRetryAttempt: Int
        switch progress {
        case .needsContinuation:
            nextContentionRetryAttempt = 0
        case .retryableContention:
            guard await coordinator.waitForContentionRetry(
                afterAttempt: contentionRetryAttempt
            ), !Task.isCancelled, isEnabled() else {
                return
            }
            nextContentionRetryAttempt = contentionRetryAttempt + 1
        case .complete, .blocked:
            return
        }
        enqueueIndexedArtifactCaptureContinuation(
            record: record,
            snapshot: snapshot,
            coordinator: coordinator,
            isEnabled: isEnabled,
            contentionRetryAttempt: nextContentionRetryAttempt
        )
    }

    private func enqueueIndexedArtifactCaptureContinuation(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot,
        coordinator: AgentArtifactCaptureCoordinator,
        isEnabled: @escaping @MainActor @Sendable () -> Bool,
        contentionRetryAttempt: Int
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
            isEnabled: isEnabled,
            contentionRetryAttempt: contentionRetryAttempt
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
        cancelDebouncedArtifactCapture(sessionID: sessionID)
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
