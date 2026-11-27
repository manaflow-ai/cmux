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
/// person is never left to send the person's prompts as an unverified sender's (Leo, 2026-11-10:
/// "Oh, it's turned me into an unverified sender."), and it is never narrated (Leo, 2026-11-22).
/// A daemon that says `reprove` holds the proof until its key lands, so ``provePerson`` settles it
/// by events and this sees only a refusal past acpmux's per-connection cap: nothing more to try.
/// An older daemon refuses an early proof: the host enrolls this launch's key
/// (``recoverPersonProof``) and, once that lookup ends, the pane reconnects once and the new
/// connection proves. No clock decides any of it.
extension AgentPaneTransport {
    func personProofSettled(_ proven: Bool, connection: Int, reprove: Bool) {
        guard connection == current else { return }
        personRecovery?.cancel()
        personRecovery = nil
        onPersonProof?(proven)
        if proven {
            personRecoveries = 0
            return
        }
        guard !reprove, let recover = recoverPersonProof, personRecoveries < Self.personRecoveryReconnects else {
            Self.logger.error("agent pane transport: the person proof did not recover; prompts here stay unverified")
            return
        }
        // task-owner: one identity recovery per unproven connection; a new connection or a proof cancels it
        // main-hop-allow: one host lookup, then one close
        personRecovery = Task { @MainActor [weak self] in
            guard await recover(), let self, !Task.isCancelled, connection == self.current else { return }
            self.personRecoveries += 1
            Self.logger.info("agent pane transport: person key given again; reconnecting to prove it")
            self.close(connection: connection)
        }
    }
}
