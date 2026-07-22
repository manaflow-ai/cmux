import CmuxAgentChat
import CmuxArtifacts
import Foundation

extension AgentChatTranscriptService {
    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        guard let artifactCaptureCoordinator, isAutomaticArtifactCaptureEnabled() else { return }
        let resolver = self.resolver
        let artifactIndex = self.artifactIndex
        let isAutomaticArtifactCaptureEnabled = self.isAutomaticArtifactCaptureEnabled
        replaceArtifactCaptureTask(sessionID: record.sessionID) {
            guard !Task.isCancelled, await isAutomaticArtifactCaptureEnabled() else { return }
            let transcriptPath: String
            do {
                guard let resolved = try resolver.transcriptPath(for: record) else { return }
                transcriptPath = resolved
            } catch {
                return
            }
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
            await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
        }
    }

    /// Reuses an already-indexed gallery snapshot without parsing the transcript again.
    func scheduleIndexedArtifactCapture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) {
        guard let artifactCaptureCoordinator, isAutomaticArtifactCaptureEnabled() else { return }
        let isAutomaticArtifactCaptureEnabled = self.isAutomaticArtifactCaptureEnabled
        replaceArtifactCaptureTask(sessionID: record.sessionID) {
            guard !Task.isCancelled, await isAutomaticArtifactCaptureEnabled() else { return }
            await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
        }
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
