import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        guard let artifactCaptureCoordinator else { return }
        let resolver = self.resolver
        let artifactIndex = self.artifactIndex
        replaceArtifactCaptureTask(sessionID: record.sessionID) {
            guard !Task.isCancelled,
                  let transcriptPath = resolver.transcriptPath(for: record),
                  !Task.isCancelled else { return }
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
        artifactCaptureTasks.removeValue(forKey: sessionID)?.cancel()
        artifactCaptureTasks[sessionID] = Task.detached(priority: .utility) {
            await operation()
        }
    }
}
