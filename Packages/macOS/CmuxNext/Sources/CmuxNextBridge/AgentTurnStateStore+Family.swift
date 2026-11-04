import Foundation

/// acpmux's sub-session links (`startedBy`, `hub/subsessions.rs`): the session whose agent started a
/// session with its `start_session` tool, or, without one, ran `acpmux new` for it (`spawnedBy`, the
/// chats the page lists as started, `started/startedSessions.ts`). Read from the session summaries of `_acpmux/watch` and its
/// `_acpmux/session_changed` pushes and kept beside the turn states, so a chat's page may open the
/// sessions of its own family (`chat.offer.open`) and nothing else.
extension AgentTurnStateStore {
    /// How far a walk up the links goes: acpmux bounds depth far below this; a cycle in bad data stops here.
    static let maxFamilyDepth = 64

    /// The session that started the one `summary` describes (`startedBy`, else `spawnedBy`, as
    /// ``RemoteAgentSessionLinks`` reads a peer's); nil for a session a person or a client started,
    /// and never the session itself. Without `spawnedBy` a chat its agent made with `acpmux new`
    /// showed in the tray and Session Info, but a click on it was refused (`chat.offer.refused`).
    public nonisolated static func startedBy(summary: [String: Any]) -> String? {
        let parent = ["startedBy", "spawnedBy"].lazy
            .compactMap { (summary[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let parent, parent != summary["sessionId"] as? String else { return nil }
        return parent
    }

    /// The parent of every sub-session of a watch result, by sub-session id.
    public nonisolated static func startedBy(_ result: [String: Any]) -> [String: String] {
        var links: [String: String] = [:]
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) {
            if let id = summary["sessionId"] as? String, let parent = startedBy(summary: summary) { links[id] = parent }
        }
        return links
    }

    // MARK: Writes (the watch feed)

    /// Sets the session that started `session` (nil: a root session, or purged).
    public func setStartedBy(_ parent: String?, session: String, source: String = AgentTurnStateStore.localSource) {
        if let record = sessions[session] {
            record.startedBy = parent
        } else if let parent {
            let record = Session()
            record.source = source
            record.startedBy = parent
            sessions[session] = record
        }
    }

    /// Replaces the links of every session of `source`'s watch with its page's.
    public func replaceStartedBy(_ links: [String: String], source: String = AgentTurnStateStore.localSource) {
        let own = sessions.compactMap { $0.value.source == source && $0.value.startedBy != nil ? $0.key : nil }
        for id in Set(own).union(links.keys) { setStartedBy(links[id], session: id, source: source) }
    }

    // MARK: Reads

    /// Whether `session` belongs to chat `chat`'s family: a sub-session under it at any depth, or
    /// the session that started it. Never the chat itself.
    public func isFamily(_ session: String, of chat: String) -> Bool {
        guard session != chat else { return false }
        if sessions[chat]?.startedBy == session { return true }
        var current = session
        for _ in 0..<Self.maxFamilyDepth {
            guard let parent = sessions[current]?.startedBy else { return false }
            if parent == chat { return true }
            current = parent
        }
        return false
    }
}
