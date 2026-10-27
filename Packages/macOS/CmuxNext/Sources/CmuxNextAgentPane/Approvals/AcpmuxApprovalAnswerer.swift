import Foundation
public import CmuxNextWakeups
import os

/// The app's ``AgentApprovalAnswering``: each read or answer is one short person-proven
/// connection to this app's acpmux (``AcpmuxPersonLine``). An answer re-reads the prompt and
/// counts only while the same request (``AcpmuxPermissionPrompt/digest(_:)``) is pending and
/// offers the option the decision maps to (``AcpmuxPermissionPrompt/option(allow:offered:)``,
/// the feed bridge's own mapping). Then `_acpmux/permission_respond`, as the chat's own Allow
/// and Deny send it.
@MainActor
public final class AcpmuxApprovalAnswerer: AgentApprovalAnswering {
    private let environment: AcpmuxEnvironment
    private let deadlines: MainDeadlineScheduler
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications.approval")

    /// - Parameters:
    ///   - environment: This app's acpmux.
    ///   - deadlines: The app's one deadline placer (`AppServices.mainDeadlines`), for each connection's limit.
    public init(environment: AcpmuxEnvironment, deadlines: MainDeadlineScheduler) {
        self.environment = environment
        self.deadlines = deadlines
    }

    public func pendingApproval(session: String) async -> AgentApproval? {
        guard let line = await AcpmuxPersonLine.open(environment, deadlines: deadlines) else { return nil }
        defer { line.close() }
        let pending = await line.pending(of: session)
        // One prompt only: with several, a banner could not say which one its buttons answer.
        guard pending.count == 1, let permission = pending[0]["permissionId"] as? String,
              let request = pending[0]["request"] as? [String: Any], AcpmuxPermissionPrompt.isToolPermission(request)
        else { return nil }
        return AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionPrompt.digest(request),
                             summary: AcpmuxPermissionPrompt.summary(request))
    }

    public func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment, deadlines: deadlines) else { return false }
        defer { line.close() }
        // acpmux refuses an allow from a connection that is not the person.
        if allow, !line.isPerson {
            logger.error("approval banner: acpmux refused this app's person proof; nothing allowed")
            return false
        }
        guard let now = await line.pending(of: approval.session).first(where: { $0["permissionId"] as? String == approval.permission }),
              let request = now["request"] as? [String: Any], AcpmuxPermissionPrompt.digest(request) == approval.digest,
              let option = AcpmuxPermissionPrompt.option(allow: allow, offered: request["options"] as? [[String: Any]] ?? [])
        else {
            logger.info("approval banner: the prompt ended or changed since its banner posted; nothing answered")
            return false
        }
        let params: [String: Any] = ["sessionId": approval.session, "permissionId": approval.permission, "optionId": option]
        return await line.call("_acpmux/permission_respond", params) != nil
    }
}
