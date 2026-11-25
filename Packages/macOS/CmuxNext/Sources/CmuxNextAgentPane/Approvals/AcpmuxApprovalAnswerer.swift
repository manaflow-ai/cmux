import Foundation
import os

/// The app's ``AgentApprovalAnswering``: each read or answer is one short person-proven
/// connection to this app's acpmux (``AcpmuxPersonLine``). An answer re-reads the prompt and
/// counts only while the same request (``AcpmuxPermissionPrompt/digest(_:)``) is pending and
/// offers the option the decision maps to (``AcpmuxPermissionPrompt/option(allow:offered:)``,
/// the feed bridge's own mapping). Then `_acpmux/permission_respond`, as the chat's own Allow
/// and Deny send it.
@MainActor
public final class AcpmuxApprovalAnswerer: AgentApprovalAnswering, AgentAskAnswering {
    private let environment: AcpmuxEnvironment
    private let chiefHomeID: String?
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications.approval")

    public init(environment: AcpmuxEnvironment, chiefHomeID: String? = nil) {
        self.environment = environment
        self.chiefHomeID = chiefHomeID
    }

    /// Home may be opened before any agent pane enrolled this daemon. Reuse
    /// signed-app enrollment and peer/home checks; never restart or hand off it.
    public func prepareForHome() async {
        guard chiefHomeID != nil, !environment.isAttached,
              let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath),
              status.serves(home: environment.home) else { return }
        _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
    }

    /// Decode the card snapshot and use the same canonicalization as both pending reads.
    public nonisolated static func requestDigest(_ json: String) -> String? {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              AcpmuxPermissionPrompt.isToolPermission(request) else { return nil }
        return AcpmuxPermissionPrompt.digest(request)
    }

    public func pendingApproval(session: String) async -> AgentApproval? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        let pending = await line.pending(of: session)
        // One prompt only: with several, a banner could not say which one its buttons answer.
        guard pending.count == 1, let permission = pending[0]["permissionId"] as? String,
              let request = pending[0]["request"] as? [String: Any], AcpmuxPermissionPrompt.isToolPermission(request)
        else { return nil }
        let offered = request["options"] as? [[String: Any]] ?? []
        return AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionPrompt.digest(request),
                             summary: AcpmuxPermissionPrompt.summary(request),
                             alwaysOffered: AcpmuxPermissionPrompt.alwaysOption(offered: offered) != nil)
    }

    /// The home inbox's read of one ask (``AgentPaneAskAnswer``): that prompt among the chat's
    /// pending ones, whatever else is pending, while it is a tool permission of a chat this daemon
    /// holds itself (never a peer's). Its options are the ask's allow once and reject once only.
    public func pendingAsk(session: String, permission: String) async -> AgentPendingAsk? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        guard let entry = await line.ownPending(of: session, chiefHomeID: chiefHomeID).first(where: { $0["permissionId"] as? String == permission }),
              let request = entry["request"] as? [String: Any], AcpmuxPermissionPrompt.isToolPermission(request) else { return nil }
        let offered = request["options"] as? [[String: Any]] ?? []
        let approval = AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionPrompt.digest(request),
                                     summary: AcpmuxPermissionPrompt.summary(request))
        return AgentPendingAsk(approval: approval, allowOnce: AcpmuxPermissionPrompt.onceOption(allow: true, offered: offered),
                               denyOnce: AcpmuxPermissionPrompt.onceOption(allow: false, offered: offered))
    }

    /// Another chat's question, read for ``AgentPaneAskAnswer``: that prompt among the chat's
    /// pending ones while it is a question of a chat this daemon holds itself (never a peer's), as
    /// the request's canonical JSON and digest, which the reply is validated against.
    public func pendingQuestion(session: String, permission: String) async -> AgentPendingQuestion? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        guard let entry = await line.ownPending(of: session, chiefHomeID: chiefHomeID).first(where: { $0["permissionId"] as? String == permission }),
              let request = entry["request"] as? [String: Any], AcpmuxPermissionPrompt.question(request) != nil,
              let json = AcpmuxSecretKey.canonicalJSON(request), let digest = AcpmuxSecretKey.canonicalDigest(request) else { return nil }
        return AgentPendingQuestion(requestJSON: json, digest: digest)
    }

    /// Sends a validated question reply as the chat's own card does (`_acpmux/permission_respond`
    /// with its `answers`), only on a person connection and only while the same request (its
    /// canonical digest) is still pending in a chat this daemon holds itself.
    public func answerQuestion(_ reply: AgentPaneQuestionReply, spend: @MainActor () -> Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment) else { return false }
        defer { line.close() }
        // A question's answer is an allow: acpmux refuses it from a connection that is not the person.
        guard line.isPerson else {
            logger.error("question answer: acpmux refused this app's person proof; nothing answered")
            return false
        }
        let input = reply.input
        guard let now = await line.ownPending(of: input.sessionId, chiefHomeID: chiefHomeID)
                .first(where: { $0["permissionId"] as? String == input.permissionId }),
              let request = now["request"] as? [String: Any],
              AcpmuxSecretKey.canonicalDigest(request) == input.requestDigest,
              var params = (try? JSONSerialization.jsonObject(with: Data(reply.canonicalJSON.utf8))) as? [String: Any] else {
            logger.info("question answer: the question ended or changed since it was read; nothing answered")
            return false
        }
        guard spend() else { return false }
        params["sessionId"] = input.sessionId
        params["permissionId"] = input.permissionId
        return await line.call("_acpmux/permission_respond", params) != nil
    }

    public func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
        await answer(approval, allow: allow, once: false) { true }
    }

    /// A banner's Always allow: the prompt's one `allow_always` option, as the chat's own card sends it.
    public func answerAlways(_ approval: AgentApproval) async -> Bool {
        await answer(approval, allow: true, once: false, always: true) { true }
    }

    /// The inbox's answer: as ``answer(_:allow:)``, but only a chat this daemon holds itself, and
    /// only the prompt's allow once or reject once (never `reject_always` in place of a missing
    /// reject once).
    public func answerOnce(_ approval: AgentApproval, allow: Bool, spend: @MainActor () -> Bool) async -> Bool {
        await answer(approval, allow: allow, once: true, spend: spend)
    }

    /// Native Home uses a gate that remains valid through the actual socket write.
    public func answerOnce(_ approval: AgentApproval, allow: Bool,
                           through gate: @escaping @Sendable (() -> Void) -> Bool) async -> Bool {
        await answer(approval, allow: allow, once: true, through: gate) { true }
    }

    private func answer(_ approval: AgentApproval, allow: Bool, once: Bool, always: Bool = false,
                        through gate: (@Sendable (() -> Void) -> Bool)? = nil,
                        spend: @MainActor () -> Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment) else { return false }
        defer { line.close() }
        // acpmux refuses an allow from a connection that is not the person.
        if allow, !line.isPerson {
            logger.error("approval banner: acpmux refused this app's person proof; nothing allowed")
            return false
        }
        let pending = once ? await line.ownPending(of: approval.session, chiefHomeID: chiefHomeID) : await line.pending(of: approval.session)
        let offered = { (request: [String: Any]) in request["options"] as? [[String: Any]] ?? [] }
        guard let now = pending.first(where: { $0["permissionId"] as? String == approval.permission }),
              let request = now["request"] as? [String: Any], AcpmuxPermissionPrompt.digest(request) == approval.digest,
              let option = always ? AcpmuxPermissionPrompt.alwaysOption(offered: offered(request))
                  : once ? AcpmuxPermissionPrompt.onceOption(allow: allow, offered: offered(request))
                  : AcpmuxPermissionPrompt.option(allow: allow, offered: offered(request))
        else {
            logger.info("approval banner: the prompt ended or changed since its banner posted; nothing answered")
            return false
        }
        guard spend() else { return false }
        let params: [String: Any] = ["sessionId": approval.session, "permissionId": approval.permission, "optionId": option]
        return await line.call("_acpmux/permission_respond", params, through: gate) != nil
    }
}
