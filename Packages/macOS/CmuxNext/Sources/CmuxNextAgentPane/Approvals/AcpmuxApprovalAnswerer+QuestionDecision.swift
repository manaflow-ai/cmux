import Foundation

/// What signing one Home question answer came to.
public enum AgentQuestionDecisionOutcome: Sendable, Equatable {
    /// The `question.answer` op's `decision` envelope, as canonical JSON text.
    case signed(String)
    /// This daemon does not hold that prompt for this home: try the next one.
    case notHere
    /// The prompt ended or changed since the daemon read it.
    case expired
    /// Not the person's line, no key, an answer the request does not take, or the click expired.
    case refused
}

extension AcpmuxApprovalAnswerer {
    /// Signs a Home answer to a Chief question (acpmux `decision_answers_proof`) after a native
    /// click. `unsignedJSON` is the daemon's `conversation-question-decision` reply. The daemon is
    /// not trusted with it: the prompt is read again here on a person-proven line, and its run
    /// (`personInstance`), one-use `decisionNonce` and request digest must match the reply. The
    /// reply's `answers` must also be an answer that request takes (``AgentPaneQuestionReply``).
    /// Only then, and only through `gate` (the click's one use), does the key sign. A proof works
    /// for that prompt, option and answers only, and acpmux spends it once.
    public func signQuestionDecision(_ unsignedJSON: String,
                                     through gate: @escaping @Sendable (() -> Void) -> Bool) async -> AgentQuestionDecisionOutcome {
        guard let unsigned = (try? JSONSerialization.jsonObject(with: Data(unsignedJSON.utf8))) as? [String: Any],
              let session = unsigned["session"] as? String, let permission = unsigned["permission"] as? String,
              let option = unsigned["option_id"] as? String, let instance = unsigned["instance"] as? String,
              let nonce = unsigned["decision_nonce"] as? String, let digest = unsigned["digest"] as? String,
              let answers = unsigned["answers"] as? [String: Any], let question = unsigned["question"],
              // The request's canonical text, not `request`: its numbers never passed through a
              // lossy JSON value on the way here.
              let claimedJSON = unsigned["request_json"] as? String,
              let claimed = (try? JSONSerialization.jsonObject(with: Data(claimedJSON.utf8))) as? [String: Any],
              // The signed identity is the raw local session id (acpmux verifies it, the daemon binds
              // it): a qualified or path-like one is not what the daemon sends.
              !session.isEmpty, !session.contains("/"), !instance.isEmpty, !nonce.isEmpty,
              // The text must be its own canonical form: the envelope carries it as the daemon hashes
              // it, and a number the app cannot write exactly (past 2^63, fractional) is refused here.
              AcpmuxSecretKey.canonicalJSON(claimed) == claimedJSON,
              AcpmuxSecretKey.canonicalDigest(claimed) == digest else { return .refused }
        guard let line = await AcpmuxPersonLine.open(environment) else { return .notHere }
        defer { line.close() }
        // The person line names the session `local/<raw>`; the proof and the reply name the raw id.
        guard let entry = await line.ownPending(of: "local/" + session, chiefHomeID: chiefHomeID)
                .first(where: { $0["permissionId"] as? String == permission }),
              let request = entry["request"] as? [String: Any] else { return .notHere }
        guard entry["personInstance"] as? String == instance, entry["decisionNonce"] as? String == nonce,
              AcpmuxSecretKey.canonicalDigest(request) == digest, let requestJSON = AcpmuxSecretKey.canonicalJSON(request)
        else { return .expired }
        // A question's answer is an allow: only the person's line, with this app's key for this daemon.
        guard line.isPerson, let key = AcpmuxPersonKey.secretKey(socketPath: environment.socketPath),
              let replyJSON = AcpmuxSecretKey.canonicalJSON(["optionId": option, "answers": answers] as [String: Any]),
              (try? AgentPaneQuestionReply(input: .init(sessionId: session, permissionId: permission,
                                                        requestJSON: requestJSON, requestDigest: digest),
                                           replyJSON: replyJSON)) != nil else { return .refused }
        var proof: String?
        guard gate({ proof = key.decisionProof(instance: instance, session: session, permission: permission,
                                               option: option, nonce: nonce, answers: answers) }),
              let proof else { return .refused }
        // `request_json` is the exact canonical text the daemon returned and this signer verified, not
        // a JSON object: the daemon hashes those bytes, so no number is rounded on the way.
        let envelope: [String: Any] = ["question": question, "request_json": claimedJSON, "digest": digest, "instance": instance,
                                       "option_id": option, "decision_nonce": nonce, "person_decision": proof]
        return AcpmuxSecretKey.canonicalJSON(envelope).map(AgentQuestionDecisionOutcome.signed) ?? .refused
    }
}
