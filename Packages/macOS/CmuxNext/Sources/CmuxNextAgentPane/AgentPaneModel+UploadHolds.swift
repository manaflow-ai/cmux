import Foundation

/// A file the page uploads at the person's Send (webviews promptBudget.ts: one too large to go
/// inline in its prompt) holds that Send's ticket (``AgentPaneUploadSendTicket``) instead of spending
/// the gesture: the person's Enter is one credit, the page reserved it as the prompt's ticket, and
/// the prompt redeems it once every upload holding it has finished or been cancelled. Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size".
extension AgentPaneModel {
    /// `chat.upload.begin` under `ticket`: the upload holds it on the transport's connection, for a
    /// chat of this pane and exactly the ticket's prompt; refused as `gestureRequired` otherwise,
    /// before the stager sees it.
    func beginSendUpload(_ stage: AgentPaneUploadStageRequest, ticket: AgentPaneUploadSendTicket) async -> [String: Any] {
        guard let stager = onUploadStage?() else { return Self.unsupported("chat.upload.stage") }
        // Only into the chat the pane shows (or the new chat it starts): the stager saves there.
        if let sessionId, sessionId != ticket.sessionId { return Self.transportFailure(.gestureRequired) }
        let hold = UUID().uuidString
        guard transport.holdSendTicket(ticket.ticket, upload: hold, sessionId: ticket.sessionId, promptId: ticket.promptId) else {
            return Self.transportFailure(.gestureRequired)
        }
        let reply = await stager(stage, sessionId)
        guard reply["ok"] as? Bool == true, let token = (reply["value"] as? [String: Any])?["token"] as? String else {
            transport.gestures.releaseUpload(hold)
            return reply
        }
        uploadHolds[token] = hold
        return reply
    }

    /// A chunk, finish or cancel of any stage: one begun under a Send's ticket reports its progress
    /// (a chunk) or ends its hold (finish, cancel). A chunk whose hold already ended (a newer Send,
    /// the connection's end, a stall) cancels its stage instead: its prompt can no longer go.
    func stageHeld(_ stage: AgentPaneUploadStageRequest, _ stager: AgentPaneUploadStager) async -> [String: Any] {
        switch stage {
        case .begin:
            return await stager(stage, sessionId)
        case .chunk(let token, _, _):
            if let hold = uploadHolds[token], !transport.gestures.uploadProgressed(hold) {
                uploadHolds[token] = nil
                _ = await stager(.cancel(token: token), sessionId)
                return Self.transportFailure(.gestureRequired)
            }
            return await stager(stage, sessionId)
        case .finish(let token), .cancel(let token):
            let reply = await stager(stage, sessionId)
            if let hold = uploadHolds.removeValue(forKey: token) { transport.gestures.releaseUpload(hold) }
            return reply
        }
    }
}
