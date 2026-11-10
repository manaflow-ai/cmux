import Foundation
import os

/// Peer-route approvals in one click (Leo, 2026-11-04: "this is such an awkward flow it doesnt let
/// me trust on click when i try it pops error or something then asks me to \"enroll\"???"). A peer of
/// this Mac's daemon refused the person's signed one-time answer because it has not enrolled this
/// Mac yet: the page never sees that refusal (``AcpmuxPaneSocket`` keeps it), this Mac enrolls
/// there through the pane's Enroll this Mac command, and the same signed answer goes once more.
/// Nothing new is signed: the answer is the one the person's click made, and it goes again at
/// most once (the retry carries no ``AcpmuxDecisionContexts/Sent/retry``). Only an enroll or a
/// send that fails lets the page have the refusal, and the notice says why.
extension AgentPaneTransport {
    func enrollThenRetry(peer: String, pageID: String, frame: String) {
        guard let socket, let approver = peerApprover, let enroll = approver.enroll else {
            socket?.releaseHeld(pageID)
            onPeerApprovalsOff?(.notEnrolled(peer: peer))
            return
        }
        let connection = current
        let daemon = approver.daemon(socket: acpmuxSocket)
        onPeerApprovalsOff?(.enrolling(peer: peer))
        // task-owner: one enroll per refused click; it ends with the answer sent again or the
        // refusal given to the page, and a reconnect meanwhile gives it the refusal
        Task { @MainActor [weak self] in
            let failure = await enroll(peer, daemon)
            guard let self else { return }
            guard connection == self.current, self.socket === socket, !socket.isClosed else {
                socket.releaseHeld(pageID)
                return
            }
            if let failure {
                socket.releaseHeld(pageID)
                self.onPeerApprovalsOff?(.enrollFailed(peer: peer, reason: failure))
                return
            }
            guard self.resend(frame, pageID: pageID, socket: socket) else {
                socket.releaseHeld(pageID)
                self.onPeerApprovalsOff?(.notEnrolled(peer: peer))
                return
            }
            socket.dropHeld(pageID)
            // Enrolled; the answer's own reply now says whether it counted.
            self.onPeerApprovalsOff?(nil)
        }
    }

    /// Sends the page's answer `frame` again under a new relay id for the same page id, so its
    /// reply reaches the page's waiting request; false when it could not go.
    private func resend(_ frame: String, pageID: String, socket: AcpmuxPaneSocket) -> Bool {
        let method = "_acpmux/permission_respond"
        guard let ids = requestIds,
              var object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any],
              object["method"] as? String == method,
              let relayID = ids.begin(pageID: pageID, method: method) else { return false }
        object["id"] = relayID
        guard let text = AcpmuxRequestIds.encode(object) else {
            ids.cancel(relayID)
            return false
        }
        decisions.sent(pageID: pageID, proved: true, single: true)
        if socket.send(text) != nil {
            ids.cancel(relayID)
            decisions.notSent(pageID: pageID)
            return false
        }
        return true
    }
}

/// The pane's own person proof (acpmux `hub/person.rs`): a connection that did not prove the
/// person is told to the pane and recovered, never left to send the person's prompts as an
/// unverified sender's (Leo, 2026-11-10: "Oh, it's turned me into an unverified sender."). The
/// proof is the second request of a connection only, so recovery gets the key to the daemon
/// (``recoverPersonProof``) and then reconnects, and the new connection proves.
extension AgentPaneTransport {
    func personProofSettled(_ proven: Bool, connection: Int) {
        guard connection == current else { return }
        personRecovery?.cancel()
        personRecovery = nil
        onPersonProof?(proven)
        if proven {
            personRecoveries = 0
            return
        }
        guard let recover = recoverPersonProof, personRecoveries < Self.personRecoveryReconnects else {
            Self.logger.error("agent pane transport: the person proof did not recover; prompts here stay unverified")
            return
        }
        let delays = personRecoveryDelays
        // task-owner: one identity recovery per unproven connection; a new connection or a proof cancels it
        personRecovery = Task { @MainActor [weak self] in
            for delay in delays {
                // wakeup-allow: bounded backoff while the pane is unproven (five waits at most)
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, connection == self.current else { return }
                guard await recover() else { continue }
                guard !Task.isCancelled, connection == self.current else { return }
                self.personRecoveries += 1
                Self.logger.info("agent pane transport: person key given again; reconnecting to prove it")
                self.close(connection: connection)
                return
            }
        }
    }
}
