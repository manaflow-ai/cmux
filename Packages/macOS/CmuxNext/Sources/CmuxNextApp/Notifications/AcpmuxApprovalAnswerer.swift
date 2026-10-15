import CmuxNextAgentPane
import Foundation
import os

/// The app's ``AgentApprovalAnswering``: each read or answer is one short person-proven
/// connection to this app's acpmux (``AcpmuxPersonLine``). An answer re-reads the prompt and
/// counts only while the same request (``AcpmuxPermissionFeedBridge/digest(_:)``) is pending and
/// offers the option the decision maps to (``AcpmuxPermissionAnswer``, the feed bridge's own
/// mapping). Then `_acpmux/permission_respond`, as the chat's own Allow and Deny send it.
@MainActor
final class AcpmuxApprovalAnswerer: AgentApprovalAnswering {
    private let environment: AcpmuxEnvironment
    private let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "notifications.approval")

    init(environment: AcpmuxEnvironment) {
        self.environment = environment
    }

    func pendingApproval(session: String) async -> AgentApproval? {
        guard let line = await AcpmuxPersonLine.open(environment) else { return nil }
        defer { line.close() }
        let pending = await line.pending(of: session)
        // One prompt only: with several, a banner could not say which one its buttons answer.
        guard pending.count == 1, let permission = pending[0]["permissionId"] as? String,
              let request = pending[0]["request"] as? [String: Any], AcpmuxPermissionAnswer.isToolPermission(request)
        else { return nil }
        return AgentApproval(session: session, permission: permission, digest: AcpmuxPermissionFeedBridge.digest(request),
                             summary: AcpmuxPermissionAnswer.summary(request))
    }

    func answer(_ approval: AgentApproval, allow: Bool) async -> Bool {
        guard let line = await AcpmuxPersonLine.open(environment) else { return false }
        defer { line.close() }
        // acpmux refuses an allow from a connection that is not the person.
        if allow, !line.isPerson {
            logger.error("approval banner: acpmux refused this app's person proof; nothing allowed")
            return false
        }
        guard let now = await line.pending(of: approval.session).first(where: { $0["permissionId"] as? String == approval.permission }),
              let request = now["request"] as? [String: Any], AcpmuxPermissionFeedBridge.digest(request) == approval.digest,
              let option = AcpmuxPermissionAnswer.option(allow: allow, offered: request["options"] as? [[String: Any]] ?? [])
        else {
            logger.info("approval banner: the prompt ended or changed since its banner posted; nothing answered")
            return false
        }
        let params: [String: Any] = ["sessionId": approval.session, "permissionId": approval.permission, "optionId": option]
        return await line.call("_acpmux/permission_respond", params) != nil
    }
}

/// How the app answers an acpmux permission for the person, shared by the feed bridge (an answer
/// from the phone) and approval banners: allow maps to the offered `allow_once` option, deny to
/// the offered reject option; an option kind offered twice maps to nothing.
nonisolated enum AcpmuxPermissionAnswer {
    static func option(allow: Bool, offered: [[String: Any]]) -> String? {
        let kinds = allow ? ["allow_once"] : ["reject_once", "reject_always"]
        for kind in kinds {
            let matches = offered.filter { $0["kind"] as? String == kind }
            if matches.count == 1, let id = matches[0]["optionId"] as? String { return id }
        }
        return nil
    }

    /// A tool permission both buttons can answer: not a question (the daemon's normalized
    /// `toolCall._meta.acpmux.question`), and it offers allow once and a deny.
    static func isToolPermission(_ request: [String: Any]) -> Bool {
        let tool = request["toolCall"] as? [String: Any]
        let acpmux = (tool?["_meta"] as? [String: Any])?["acpmux"] as? [String: Any]
        let offered = request["options"] as? [[String: Any]] ?? []
        return acpmux?["question"] == nil && option(allow: true, offered: offered) != nil
            && option(allow: false, offered: offered) != nil
    }

    /// What the prompt asks to do, for a banner: its tool call's title, then the command it runs,
    /// secrets scrubbed and invisible characters shown (as the feed bridge shows them).
    static func summary(_ request: [String: Any]) -> String {
        let call = request["toolCall"] as? [String: Any] ?? [:]
        let input = call["rawInput"] as? [String: Any] ?? [:]
        let lines = [call["title"] as? String, AcpmuxPermissionFeedBridge.shownCommand(input["command"])]
            .compactMap { $0.map { AcpmuxPermissionFeedBridge.visible(FeedSecretScrubber.scrub($0)) } }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = lines.count == 2 && lines[0] == lines[1] ? [lines[0]] : lines
        return AcpmuxPermissionFeedBridge.cut(unique.joined(separator: "\n"), 300)
    }
}
