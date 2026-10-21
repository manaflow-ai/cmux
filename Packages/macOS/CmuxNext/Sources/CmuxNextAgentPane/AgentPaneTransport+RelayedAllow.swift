import Foundation
import os

/// The decision proof a relayed allow carries (cx-0q7o), for ``AgentPaneTransport/decide(_:_:connection:socket:ids:)``.
extension AgentPaneTransport {
    /// The decision proof of an allow for a prompt of another daemon run, from the newest
    /// `permission_pending` of that prompt. The daemon's own prompts need none (this connection
    /// is the person). Signed only in a chat on another machine, only with the key bound to that
    /// chat's own machine and to the run that asks, and only for the prompt and option the person
    /// picked (`ticketPick`). A peer of this Mac's daemon has no key of this app (the app has no
    /// exec channel of its own there). Otherwise the allow goes unproved (that daemon refuses
    /// it), and the pane says so.
    func signRelayedAllow(_ box: FrameBox, sessionId: String?, ticketPick: Bool) {
        guard let session = sessionId, let permission = box.param("permissionId"), let option = box.param("optionId"),
              let context = decisions.context(session: session, permission: permission),
              context.instance != decisions.localInstance else { return }
        // No key bound for the chat's machine and the run that asks: approvals are off there.
        guard let machine = remoteApprovals?.machineID,
              let key = AcpmuxRemotePersonKeys.shared.key(machine: machine, instance: context.instance) else {
            onRemoteApprovalsOff?(remoteApprovals)
            return
        }
        // A bound key, but no ticket for this pick: the allow goes unproved and that daemon
        // refuses it. Approvals are on there, so the pane shows no notice.
        guard ticketPick else {
            Self.logger.info("agent pane transport relayed allow without the person's ticket: sent without a proof")
            return
        }
        let proof = key.decisionProof(instance: context.instance, session: session, permission: permission, option: option,
                                      nonce: context.nonce)
        box.setDecision(nonce: context.nonce, proof: proof)
    }
}
