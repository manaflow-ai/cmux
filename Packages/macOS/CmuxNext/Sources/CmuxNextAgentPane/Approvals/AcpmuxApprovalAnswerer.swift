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
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications.approval")

    public init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    public func pendingApproval(session: String) async -> AgentApproval? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        let pending = await line.pending(of: session)
        // One prompt only: with several, a banner could not say which one its buttons answer.
        guard pending.count == 1, let permission = pending[0]["permissionId"] as? String,
              let request = pending[0]["request"] as? [String: Any], AcpmuxPermissionPrompt.isToolPermission(request)
        else { return nil }
        return AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionPrompt.digest(request),
                             summary: AcpmuxPermissionPrompt.summary(request))
    }

    /// The home inbox's read of one ask (``AgentPaneAskAnswer``): that prompt among the chat's
    /// pending ones, whatever else is pending, while it is a tool permission of a chat this daemon
    /// holds itself (never a peer's). Its options are the ask's allow once and reject once only.
    public func pendingAsk(session: String, permission: String) async -> AgentPendingAsk? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        guard let entry = await line.ownPending(of: session).first(where: { $0["permissionId"] as? String == permission }),
              let request = entry["request"] as? [String: Any], AcpmuxPermissionPrompt.isToolPermission(request) else { return nil }
        let offered = request["options"] as? [[String: Any]] ?? []
        let approval = AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionPrompt.digest(request),
                                     summary: AcpmuxPermissionPrompt.summary(request))
        return AgentPendingAsk(approval: approval, allowOnce: AcpmuxPermissionPrompt.onceOption(allow: true, offered: offered),
                               denyOnce: AcpmuxPermissionPrompt.onceOption(allow: false, offered: offered))
    }

    public func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
        await answer(approval, allow: allow, once: false) { true }
    }

    /// The inbox's answer: as ``answer(_:allow:)``, but only a chat this daemon holds itself, and
    /// only the prompt's allow once or reject once (never `reject_always` in place of a missing
    /// reject once).
    public func answerOnce(_ approval: AgentApproval, allow: Bool, spend: @MainActor () -> Bool) async -> Bool {
        await answer(approval, allow: allow, once: true, spend: spend)
    }

    private func answer(_ approval: AgentApproval, allow: Bool, once: Bool, spend: @MainActor () -> Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment) else { return false }
        defer { line.close() }
        // acpmux refuses an allow from a connection that is not the person.
        if allow, !line.isPerson {
            logger.error("approval banner: acpmux refused this app's person proof; nothing allowed")
            return false
        }
        let pending = once ? await line.ownPending(of: approval.session) : await line.pending(of: approval.session)
        let offered = { (request: [String: Any]) in request["options"] as? [[String: Any]] ?? [] }
        guard let now = pending.first(where: { $0["permissionId"] as? String == approval.permission }),
              let request = now["request"] as? [String: Any], AcpmuxPermissionPrompt.digest(request) == approval.digest,
              let option = once ? AcpmuxPermissionPrompt.onceOption(allow: allow, offered: offered(request))
                  : AcpmuxPermissionPrompt.option(allow: allow, offered: offered(request))
        else {
            logger.info("approval banner: the prompt ended or changed since its banner posted; nothing answered")
            return false
        }
        guard spend() else { return false }
        let params: [String: Any] = ["sessionId": approval.session, "permissionId": approval.permission, "optionId": option]
        return await line.call("_acpmux/permission_respond", params) != nil
    }
}
