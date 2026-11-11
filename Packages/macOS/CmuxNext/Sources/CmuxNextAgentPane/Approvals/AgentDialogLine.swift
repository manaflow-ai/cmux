import Foundation

/// One short connection to this app's acpmux that the app's dialog desk (`feed.list`,
/// `feed.permission.reply`, `feed.question.reply`) reads and answers on. The app's is
/// ``AcpmuxPersonLine`` (proven as the person); tests pass a fake.
@MainActor
public protocol AgentDialogLine: AnyObject {
    /// acpmux took this connection's person proof.
    var isPerson: Bool { get }
    /// The surfaces this acpmux serves (`initialize`'s `_meta.acpmux.capabilities`).
    var capabilities: Set<String> { get }
    /// One request; its `result`, or nil when it failed or the connection closed.
    func call(_ method: String, _ params: [String: Any]) async -> [String: Any]?
    /// The `error.message` of the last request acpmux refused, nil when none was.
    var lastError: String? { get }
    func close()
}

public extension AgentDialogLine {
    var capabilities: Set<String> { [] }
    var lastError: String? { nil }
}

extension AcpmuxPersonLine: AgentDialogLine {}

/// One pending prompt as acpmux reports it (``AgentDialogLine/pendingPrompts()``).
public struct AgentDialogPrompt {
    public let session: String
    public let sessionName: String?
    public let permission: String
    public let request: [String: Any]

    /// The acpmux capability of `_acpmux/sessions {pendingOnly: true}`.
    public static let pendingListCapability = AcpmuxSessionListGate.pendingCapability
}

public extension AgentDialogLine {
    /// Every session's pending prompts: the sessions with one (``AcpmuxSessionListGate``:
    /// `pendingOnly` from an acpmux that serves it, never paced, else the list page by page),
    /// then `_acpmux/info` for each. Empty when the session list fails.
    func pendingPrompts() async -> [AgentDialogPrompt] {
        let gate = AcpmuxSessionListGate(capabilities: capabilities)
        guard let sessions = await gate.pendingSessions(call: { await self.call($0, $1) }) else { return [] }
        return await prompts(of: sessions)
    }

    /// The pending prompts of each listed session that reports one (`_acpmux/info`).
    private func prompts(of sessions: [[String: Any]]) async -> [AgentDialogPrompt] {
        var out: [AgentDialogPrompt] = []
        for summary in sessions where (summary["pendingPermissions"] as? NSNumber)?.intValue ?? 0 > 0 {
            guard let session = summary["sessionId"] as? String else { continue }
            let entries = (await call("_acpmux/info", ["sessionId": session]))?["pending"] as? [[String: Any]] ?? []
            for entry in entries {
                guard let permission = entry["permissionId"] as? String, let request = entry["request"] as? [String: Any] else { continue }
                out.append(AgentDialogPrompt(session: session, sessionName: summary["name"] as? String, permission: permission, request: request))
            }
        }
        return out
    }
}
