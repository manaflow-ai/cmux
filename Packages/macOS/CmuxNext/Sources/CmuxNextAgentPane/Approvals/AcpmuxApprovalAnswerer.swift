public import Foundation
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

    public func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment) else { return false }
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

    /// Why ``answer(session:permission:allow:)`` answered nothing; its text is shown where the
    /// person clicked (the Home approval card).
    public enum Refusal: Error, Equatable, LocalizedError {
        /// No acpmux answers on this environment's socket.
        case noDaemon
        /// acpmux did not take this app's person proof, so it would refuse an allow.
        case notPerson
        /// The prompt ended (answered elsewhere, the turn stopped) or offers no matching option.
        case notPending
        /// acpmux refused the answer.
        case refused

        public var errorDescription: String? {
            switch self {
            case .noDaemon: String(localized: "approval.answer.noDaemon", defaultValue: "The Chief is not running", bundle: .module)
            case .notPerson:
                String(localized: "approval.answer.notPerson", defaultValue: "The Chief did not accept this app as you", bundle: .module)
            case .notPending:
                String(localized: "approval.answer.notPending", defaultValue: "The Chief is no longer waiting for this", bundle: .module)
            case .refused: String(localized: "approval.answer.refused", defaultValue: "The Chief refused the answer", bundle: .module)
            }
        }
    }

    /// Answers `permission` of `session` (allow once, else deny), as the person: the Home approval
    /// card's Allow and Deny. The app gives this daemon its person key first (a daemon the app did
    /// not start, as the Chief's, takes it by the app's signature, `AcpmuxPersonKey.enroll`), so an
    /// allow counts with no Chief tab attached this launch.
    public func answer(session: String, permission: String, allow: Bool) async throws {
        if allow, let status = try? await AcpmuxStatusClient.status(socketPath: environment.socketPath) {
            _ = await AcpmuxPersonKey.enroll(status, environment: environment, mayHandOff: false)
        }
        guard let line = await AcpmuxPersonLine.open(environment) else { throw Refusal.noDaemon }
        defer { line.close() }
        if allow, !line.isPerson {
            logger.error("approval card: acpmux refused this app's person proof; nothing allowed")
            throw Refusal.notPerson
        }
        guard let now = await line.pending(of: session).first(where: { $0["permissionId"] as? String == permission }),
              let request = now["request"] as? [String: Any],
              let option = AcpmuxPermissionPrompt.option(allow: allow, offered: request["options"] as? [[String: Any]] ?? [])
        else { throw Refusal.notPending }
        let params: [String: Any] = ["sessionId": session, "permissionId": permission, "optionId": option]
        guard await line.call("_acpmux/permission_respond", params) != nil else { throw Refusal.refused }
    }
}
