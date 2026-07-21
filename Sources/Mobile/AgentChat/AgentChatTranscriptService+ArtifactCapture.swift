import CmuxAgentChat
import Foundation

extension AgentChatTranscriptService {
    /// Captures one authoritative transcript generation after an agent turn.
    func scheduleArtifactCapture(for record: AgentChatSessionRecord) {
        guard let artifactCaptureCoordinator,
              let transcriptPath = resolver.transcriptPath(for: record) else {
            return
        }
        Task {
            guard let snapshot = try? await artifactIndex.snapshot(
                sessionID: record.sessionID,
                agentKind: record.agentKind,
                transcriptPath: transcriptPath,
                workingDirectory: record.workingDirectory
            ) else {
                return
            }
            await artifactCaptureCoordinator.capture(record: record, snapshot: snapshot)
        }
    }

    /// Reuses an already-indexed gallery snapshot without parsing the transcript again.
    func captureIndexedArtifacts(
        record: AgentChatSessionRecord,
        snapshot: AgentChatArtifactIndex.Snapshot
    ) async {
        await artifactCaptureCoordinator?.capture(record: record, snapshot: snapshot)
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
}
