import Foundation
import CmuxNextPages

extension AgentPaneTransport {
    struct CapturedQuestionKeyReply {
        let connection: Int
        let target: PageQuestionKeyTarget
    }

    /// Record the capture before admission or any DOM-redemption await. The socket's inbox may
    /// be dropped on overflow, so it cannot be the only owner of the card's pending request.
    @discardableResult
    func beginQuestionKeyReply(connection: Int, requestID: String, target: PageQuestionKeyTarget) -> Bool {
        capturedQuestionKeyReplies[requestID] = CapturedQuestionKeyReply(connection: connection, target: target)
        guard connection == current, let socket, !socket.isClosed else {
            rejectQuestionKeyReply(connection: connection, requestID: requestID, target: target,
                                   error: connection == current ? .closed : .staleConnection)
            return false
        }
        if let announcement = questionKeyAnnouncement(requestID: requestID, target: target) {
            // Admission failures can precede the next socket flush. Deliver the announcement
            // now so no stale queued copy can recreate an already-refused promise afterward.
            deliver?(AgentPaneTransportEvent(connection: connection, frames: [announcement], closed: nil)) {}
        }
        return true
    }

    /// The announcement precedes the send, so even an immediate daemon refusal reaches the
    /// card's adopted promise. Admission and close failures use the host delivery path below.
    func submitQuestionKeyReply(connection: Int, requestID: String, target: PageQuestionKeyTarget, frame: String) {
        if capturedQuestionKeyReplies[requestID] == nil,
           !beginQuestionKeyReply(connection: connection, requestID: requestID, target: target) { return }
        guard connection == current, let socket, !socket.isClosed else {
            rejectQuestionKeyReply(connection: connection, requestID: requestID, target: target,
                                   error: connection == current ? .closed : .staleConnection)
            return
        }
        submit(connection: connection, frames: [frame]) { [weak self] error in
            guard let self, let error, self.capturedQuestionKeyReplies[requestID] != nil else { return }
            self.rejectQuestionKeyReply(connection: connection, requestID: requestID, target: target, error: error)
        }
    }

    /// Bypass the dead socket, not the page bridge. A paired announcement/error can be displayed
    /// by its card even after BridgeSocket has removed the closed connection. It never sends ACP.
    func rejectQuestionKeyReply(connection: Int, requestID: String, target: PageQuestionKeyTarget,
                                error: AgentPaneTransportError = .gestureRequired) {
        capturedQuestionKeyReplies.removeValue(forKey: requestID)
        let frames = questionKeyRefusal(requestID: requestID, target: target, error: error)
        deliver?(AgentPaneTransportEvent(connection: connection, frames: frames, closed: nil)) {}
    }

    func failQuestionKeyReplies(connection: Int, error: AgentPaneTransportError) {
        let frames = takeQuestionKeyRefusals(connection: connection, error: error)
        guard !frames.isEmpty else { return }
        deliver?(AgentPaneTransportEvent(connection: connection, frames: frames, closed: nil)) {}
    }

    func takeQuestionKeyRefusals(connection: Int, error: AgentPaneTransportError) -> [String] {
        let captured = capturedQuestionKeyReplies.filter { $0.value.connection == connection }
        var frames: [String] = []
        for (requestID, reply) in captured {
            capturedQuestionKeyReplies.removeValue(forKey: requestID)
            frames += questionKeyRefusal(requestID: requestID, target: reply.target, error: error)
        }
        return frames
    }

    /// Answers already in a close batch win over the synthetic close error. Retire each request
    /// once; a later send completion cannot create a second promise for the same captured Return.
    func finishQuestionKeyReplies(frames: [String]) {
        guard !capturedQuestionKeyReplies.isEmpty else { return }
        for text in frames {
            guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  frame["method"] == nil, frame["result"] != nil || frame["error"] != nil,
                  let requestID = frame["id"] as? String else { continue }
            capturedQuestionKeyReplies.removeValue(forKey: requestID)
        }
    }

    private func questionKeyAnnouncement(requestID: String, target: PageQuestionKeyTarget) -> String? {
        AcpmuxRequestIds.encode(["jsonrpc": "2.0", "method": "_cmux/question_key_request", "params": [
            "id": requestID, "sessionId": target.sessionID, "permissionId": target.permissionID,
        ]])
    }

    private func questionKeyRefusal(requestID: String, target: PageQuestionKeyTarget,
                                    error: AgentPaneTransportError) -> [String] {
        guard let announcement = questionKeyAnnouncement(requestID: requestID, target: target),
              let rawID = AcpmuxPaneMethods.rawID(requestID) else { return [] }
        return [announcement, AcpmuxPaneMethods.refusal(requestID: rawID, error: error,
                                                       method: "_acpmux/permission_respond")]
    }
}
