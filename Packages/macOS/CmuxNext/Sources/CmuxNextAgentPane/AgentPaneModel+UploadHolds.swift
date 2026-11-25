import Foundation

/// A file the page uploads at the person's Send (webviews promptBudget.ts: one too large to go
/// inline in its prompt) holds that Send's ticket (``AgentPaneUploadSendTicket``) instead of spending
/// the gesture: the person's Enter is one credit, the page reserved it as the prompt's ticket, and
/// the prompt redeems it once every upload holding it has finished or been cancelled. Leo,
/// 2026-10-31: "this is completely hardlocked bc of message size".
extension AgentPaneModel {
    /// `chat.upload.begin` under `ticket`: the upload holds it on the transport's connection, for a
    /// chat of this pane and exactly the ticket's prompt; refused as `gestureRequired` otherwise,
    /// before the stager sees it. One file per begin: a batch (its manifest or its token) would let
    /// later begins skip the ticket, so a held begin names neither.
    func beginSendUpload(_ stage: AgentPaneUploadStageRequest, ticket: AgentPaneUploadSendTicket) async -> [String: Any] {
        guard case .begin(_, _, nil, nil) = stage else { return Self.unsupported("chat.upload.begin") }
        guard let stager = onUploadStage?() else { return Self.unsupported("chat.upload.stage") }
        // Only into the chat the pane shows (or the new chat it starts): the stager saves there.
        if let sessionId, sessionId != ticket.sessionId { return Self.transportFailure(.gestureRequired) }
        watchUploadHolds()
        let hold = UUID().uuidString
        guard transport.holdSendTicket(ticket.ticket, upload: hold, sessionId: ticket.sessionId, promptId: ticket.promptId) else {
            return Self.transportFailure(.gestureRequired)
        }
        let reply = await stager(stage, sessionId)
        guard reply["ok"] as? Bool == true, let token = (reply["value"] as? [String: Any])?["token"] as? String else {
            transport.gestures.releaseUpload(hold)
            return reply
        }
        // The ticket ended while the stage began (a newer Send, the connection's end): drop the stage.
        guard transport.gestures.holdsTicket(upload: hold) else {
            _ = await stager(.cancel(token: token), sessionId)
            return Self.transportFailure(.gestureRequired)
        }
        uploadHolds[token] = hold
        return reply
    }

    /// A chunk, finish or cancel of any stage: one begun under a Send's ticket reports its progress
    /// (a chunk the stager took) or ends its hold (finish, cancel). A chunk whose hold already ended
    /// (a newer Send, the connection's end, a stall) cancels its stage instead: its prompt can no
    /// longer go. An empty chunk of a held stage is refused: it is no progress, and must not keep
    /// the hold from stalling out.
    func stageHeld(_ stage: AgentPaneUploadStageRequest, _ stager: AgentPaneUploadStager) async -> [String: Any] {
        switch stage {
        case .begin:
            return await stager(stage, sessionId)
        case .chunk(let token, _, let data):
            guard let hold = uploadHolds[token] else { return await stager(stage, sessionId) }
            guard !data.isEmpty, transport.gestures.holdsTicket(upload: hold) else {
                return await endHeldStage(token, stager)
            }
            let reply = await stager(stage, sessionId)
            guard reply["ok"] as? Bool == true else { return reply }
            // Progress counts only once the stager took the bytes.
            guard uploadHolds[token] == hold, transport.gestures.uploadProgressed(hold) else {
                return await endHeldStage(token, stager)
            }
            return reply
        case .finish(let token):
            guard let hold = uploadHolds[token] else { return await stager(stage, sessionId) }
            // The transfer after the last chunk (Cloud, a peer) reports no progress: it holds the ticket
            // until it returns.
            guard transport.gestures.uploadFinishing(hold) else { return await endHeldStage(token, stager) }
            let reply = await stager(stage, sessionId)
            // A finish that did not complete leaves no stage behind that could still upload once the
            // ticket is spent: it is cancelled before the hold lets the prompt go.
            if reply["ok"] as? Bool != true { _ = await stager(.cancel(token: token), sessionId) }
            if uploadHolds.removeValue(forKey: token) != nil { transport.gestures.releaseUpload(hold) }
            return reply
        case .cancel(let token):
            let reply = await stager(stage, sessionId)
            if let hold = uploadHolds.removeValue(forKey: token) { transport.gestures.releaseUpload(hold) }
            return reply
        }
    }

    /// Cancels the held stage `token` whose hold ended, and refuses the frame that found it so.
    private func endHeldStage(_ token: String, _ stager: AgentPaneUploadStager) async -> [String: Any] {
        if let hold = uploadHolds.removeValue(forKey: token) { transport.gestures.releaseUpload(hold) }
        _ = await stager(.cancel(token: token), sessionId)
        return Self.transportFailure(.gestureRequired)
    }

    /// Cancels the stages whose holds the gestures ended (a newer Send's ticket, a prompt that went
    /// out, the connection's end, a stall), so none of them uploads after its ticket is gone. Each
    /// stays listed until its cancel ran: a chunk or finish meanwhile finds its hold ended and is
    /// refused (``stageHeld(_:_:)``).
    private func watchUploadHolds() {
        transport.gestures.onUploadHoldsEnded = { [weak self] ended in
            guard let self else { return }
            for (token, hold) in self.uploadHolds where ended.contains(hold) {
                guard let stager = self.onUploadStage?() else {
                    self.uploadHolds[token] = nil
                    continue
                }
                Task { @MainActor [weak self] in
                    _ = await stager(.cancel(token: token), self?.sessionId)
                    if self?.uploadHolds[token] == hold { self?.uploadHolds[token] = nil }
                }
            }
        }
    }
}
