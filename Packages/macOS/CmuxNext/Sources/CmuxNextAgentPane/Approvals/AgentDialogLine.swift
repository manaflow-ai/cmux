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
    func close()
}

public extension AgentDialogLine {
    var capabilities: Set<String> { [] }
}

extension AcpmuxPersonLine: AgentDialogLine {}

/// One pending prompt as acpmux reports it (``AgentDialogLine/pendingPrompts()``).
public struct AgentDialogPrompt {
    public let session: String
    public let sessionName: String?
    public let permission: String
    public let request: [String: Any]

    /// The acpmux capability of `_acpmux/sessions {pendingOnly: true}`.
    public static let pendingListCapability = "session-list-pending-v1"
}

public extension AgentDialogLine {
    /// Every session's pending prompts: `_acpmux/sessions`, then `_acpmux/info` for each session
    /// with one. Empty when the session list fails.
    func pendingPrompts() async -> [AgentDialogPrompt] {
        let sessions: [[String: Any]]
        // `pendingOnly`: only the chats with an ask, never paced (acpmux `list_reply.rs`). Paging
        // the whole list took 4-9 s a page on a host mirroring 8,500 chats, past the 5 s line.
        if capabilities.contains(AgentDialogPrompt.pendingListCapability) {
            guard let rows = (await call("_acpmux/sessions", ["pendingOnly": true]))?["sessions"] as? [[String: Any]] else { return [] }
            sessions = rows
        } else {
            guard let rows = await allSessions() else { return [] }
            sessions = rows
        }
        return await prompts(of: sessions)
    }

    /// Every session, page by page, from an acpmux without `pendingOnly`; nil on a failed page.
    private func allSessions() async -> [[String: Any]]? {
        var sessions: [[String: Any]] = []
        var cursor: String?
        var seen: Set<String> = []
        var seenSessions: Set<String> = []
        while true { // wakeup-allow: each pass awaits a daemon page; a terminal page, malformed reply, or repeated cursor ends it
            var params: [String: Any] = ["limit": 64]
            if let cursor { params["cursor"] = cursor }
            guard let page = await call("_acpmux/sessions", params) else { return nil }
            guard let pageRows = page["sessions"] as? [[String: Any]] else { return nil }
            for row in pageRows {
                guard let id = row["sessionId"] as? String, !id.isEmpty else { continue }
                let peer = row["peer"] as? String ?? ""
                let key = "\(peer)/\(id)"
                if seenSessions.insert(key).inserted { sessions.append(row) }
            }
            guard let next = (page["nextCursor"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { break }
            guard seen.insert(next).inserted else { return nil }
            cursor = next
        }
        return sessions
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
