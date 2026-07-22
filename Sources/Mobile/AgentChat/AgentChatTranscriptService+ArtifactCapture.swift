import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        guard let artifactCaptureCoordinator else { return }
        let resolver = self.resolver
        let artifactIndex = self.artifactIndex
        replaceArtifactCaptureTask(sessionID: record.sessionID) {
            guard !Task.isCancelled else { return }
            let transcriptPath: String
            do {
                guard let resolved = try resolver.transcriptPath(for: record) else { return }
                transcriptPath = resolved
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let snapshot = try? await artifactIndex.snapshot(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                workingDirectory: record.workingDirectory
            ) else {
                return
            }
            guard !Task.isCancelled else { return }
            await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
        }
    }

    /// Reuses an already-indexed gallery snapshot without parsing the transcript again.
    func scheduleIndexedArtifactCapture(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) {
        guard let artifactCaptureCoordinator else { return }
        replaceArtifactCaptureTask(sessionID: record.sessionID) {
            guard !Task.isCancelled else { return }
            await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
        }
    }

    func saveArtifact(
        record: AgentChatSessionRecord,
        sourceURL: URL
    ) async throws -> ChatArtifactSaveResult {
        guard let artifactCaptureCoordinator else {
            throw AgentArtifactCaptureSaveError.rejected
        }
        return try await artifactCaptureCoordinator.save(record: record, sourceURL: sourceURL)
    }

    private func replaceArtifactCaptureTask(
        sessionID: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        artifactCaptureTasks.removeValue(forKey: sessionID)?.task?.cancel()
        let token = UUID()
        artifactCaptureTasks[sessionID] = (token: token, task: nil)
        let task = Task.detached(priority: .utility) { [weak self] in
            await operation()
            await self?.finishArtifactCaptureTask(sessionID: sessionID, token: token)
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
}
