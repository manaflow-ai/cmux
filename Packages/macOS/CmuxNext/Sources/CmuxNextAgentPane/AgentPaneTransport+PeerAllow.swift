import Foundation
import os

/// Peer-route approvals: an Allow for a prompt of a peer of this Mac's daemon (a chat opened with
/// `--host`), signed by this Mac's approver key (``AcpmuxMacApprover``) and counted by the peer when
/// it enrolled this Mac (`acpmux host enroll`, acpmux `hub/mac_approvers.rs`).
extension AgentPaneTransport {
    /// One prompt's allow: signed when it is a one-time allow the prompt offers (acpmux
    /// `mac_approvers::may_allow`), for the prompt and option the person picked (`ticketPick`). The
    /// peer counts it once if it enrolled this Mac, and refuses it otherwise, naming itself, and
    /// the pane offers to enroll this Mac there. Anything else (an always-allow, an answer with
    /// notes) goes unproved, and the pane says only a one-time Allow works from this Mac. The enclave signs off the main actor; a prompt
    /// that changed meanwhile goes unproved.
    func signPeerAllow(_ box: FrameBox, session: String, permission: String, option: String,
                       context: AcpmuxDecisionContexts.Context, ticketPick: Bool) async {
        guard ticketPick else {
            Self.logger.info("agent pane transport peer allow without the person's ticket: sent without a proof")
            return
        }
        guard context.allowOnce.contains(option), Self.param("annotations", box) == nil else {
            onPeerApprovalsOff?(.onceOnly)
            return
        }
        var answers = ""
        if let given = Self.param("answers", box) {
            guard let digest = AcpmuxSecretKey.canonicalDigest(given) else {
                Self.logger.info("agent pane transport peer answer without a canonical form: sent without a proof")
                return
            }
            answers = digest
        }
        guard let decision = await peerApprover?.key.decision(
            instance: context.instance, session: session, permission: permission, toolCall: context.toolCall,
            option: option, nonce: context.nonce, answers: answers) else { return }
        guard decisions.context(session: session, permission: permission) == context else { return }
        box.setDecision(nonce: context.nonce, proof: decision, field: "approverDecision")
    }

    /// A group's Allow once (`_acpmux/permission_group_respond`, the card's Allow for a batch of
    /// tool prompts), after the person's click: one signed one-time allow per pending member of the
    /// group at the revision the page answers, each over that member's prompt, tool call and the
    /// option the group's Allow selects for it, in `_meta.acpmux.approverDecisions` (acpmux
    /// `person.rs`). Only a peer's group: each member a prompt of another daemon run than this
    /// Mac's, on this Mac's daemon. Allow for this chat goes unproved (a lasting grant no Mac
    /// gives), and the pane says only a one-time Allow works from this Mac.
    func signPeerGroupAllow(_ box: FrameBox) async {
        guard remoteApprovals == nil, !remoteWire,
              let session = box.param("sessionId"), let id = box.param("groupId"), let decision = box.param("decision"),
              decision != "deny", let revision = (Self.param("revision", box) as? NSNumber)?.uint64Value,
              let group = decisions.group(session: session, id: id), group.revision == revision, !group.pending.isEmpty
        else { return }
        let members = group.pending.compactMap { permission, option in
            decisions.context(session: session, permission: permission).map { (permission, option, $0) }
        }
        guard members.count == group.pending.count,
              members.allSatisfy({ $0.2.instance != decisions.localInstance }) else { return }
        guard decision == "allow_once", members.allSatisfy({ !$0.1.isEmpty && $0.2.allowOnce.contains($0.1) }) else {
            onPeerApprovalsOff?(.onceOnly)
            return
        }
        var signed: [String: [String: any Sendable]] = [:]
        for (permission, option, context) in members {
            guard let proof = await peerApprover?.key.decision(
                instance: context.instance, session: session, permission: permission, toolCall: context.toolCall,
                option: option, nonce: context.nonce, answers: "") else { return }
            signed[permission] = ["decisionNonce": context.nonce, "approverDecision": proof]
        }
        // The group or a prompt changed while the enclave signed: the page's answer goes unproved.
        guard decisions.group(session: session, id: id) == group,
              members.allSatisfy({ decisions.context(session: session, permission: $0.0) == $0.2 }) else { return }
        box.setAcpmuxMeta("approverDecisions", signed)
    }
}
