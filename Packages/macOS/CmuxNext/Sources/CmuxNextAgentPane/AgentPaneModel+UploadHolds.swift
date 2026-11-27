import Foundation

/// A file the page uploads at the person's Send (webviews promptBudget.ts: one too large to go
/// inline in its prompt). It once held the Send's gesture ticket until it finished, so a slow upload
/// did not cost the Send its gesture (Leo, 2026-10-31: "this is completely hardlocked bc of message
/// size"). A Send needs no key press or click now (Leo, 2026-11-17, on "Not sent: it needs your own
/// key press or click": "go remove this"), so the upload just stages.
extension AgentPaneModel {
    /// `chat.upload.begin` under `ticket`: only into the chat the pane shows (or the new chat it
    /// starts), where the stager saves. One file per begin: a held begin names no batch.
    func beginSendUpload(_ stage: AgentPaneUploadStageRequest, ticket: AgentPaneUploadSendTicket) async -> [String: Any] {
        guard case .begin(_, _, nil, nil) = stage else { return Self.unsupported("chat.upload.begin") }
        guard let stager = onUploadStage?() else { return Self.unsupported("chat.upload.stage") }
        if let sessionId, sessionId != ticket.sessionId { return Self.transportFailure(.gestureRequired) }
        return await stager(stage, sessionId)
    }
}
