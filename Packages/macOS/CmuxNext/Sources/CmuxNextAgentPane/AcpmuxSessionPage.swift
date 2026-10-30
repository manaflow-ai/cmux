import Foundation

/// One page of an acpmux peer's closed chats, newest first: `_acpmux/sessions {peer, status:
/// "closed", limit, cursor}` on this Mac's daemon, which answers from the peer rows it mirrors (no
/// peer is asked). The sidebar's Older row reads a page at a time instead of the whole list.
public nonisolated struct AcpmuxSessionPage: Sendable {
    /// One closed chat.
    public struct Chat: Hashable, Sendable {
        public let id: String
        public let title: String
        public let harness: String?

        public init(id: String, title: String, harness: String?) {
            (self.id, self.title, self.harness) = (id, title, harness)
        }
    }

    /// The chats and the cursor of the next page (nil when this was the last).
    public struct Page: Hashable, Sendable {
        public let chats: [Chat]
        public let next: String?

        public init(chats: [Chat], next: String?) {
            (self.chats, self.next) = (chats, next)
        }
    }

    let socketPath: String

    public init(socketPath: String) { self.socketPath = socketPath }

    @concurrent public func closed(peer: String, cursor: String?, limit: Int, deadline: Duration = .seconds(2)) async throws -> Page {
        var params: [String: any Sendable] = ["peer": peer, "status": "closed", "limit": limit]
        if let cursor { params["cursor"] = cursor }
        let result = try await AcpmuxStatusClient.call(socketPath: socketPath, method: "_acpmux/sessions", params: params, deadline: deadline)
        return Self.page(result, peer: peer)
    }

    /// One session by id, open or closed, on this Mac or a peer it mirrors (`peer` names that
    /// peer, nil for this Mac's): the `cmux://session/<id>` question names it. Nil when acpmux has
    /// no such session. `_acpmux/resolve` reads one local or mirrored row in
    /// its exact-id mode.
    @concurrent public func session(_ id: String, deadline: Duration = .seconds(2)) async throws -> (chat: Chat, peer: String?)? {
        guard let result = try await AcpmuxStatusClient.sessionSummary(socketPath: socketPath, sessionId: id, deadline: deadline) else { return nil }
        return Self.chat(id, in: result)
    }

    static func chat(_ id: String, in summary: [String: Any]) -> (chat: Chat, peer: String?)? {
        guard summary["sessionId"] as? String == id else { return nil }
        let name = summary["name"] as? String ?? id
        let title = (summary["title"] as? String).flatMap { $0.isEmpty || $0 == name ? nil : $0 }
            ?? String(name.split(separator: "/").last ?? Substring(name))
        let peer = (summary["peer"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (Chat(id: id, title: title, harness: (summary["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 }), peer)
    }

    /// Compatibility parser for a list result used by older callers and tests.
    static func session(_ id: String, in result: [String: Any]) -> (chat: Chat, peer: String?)? {
        guard let summary = (result["sessions"] as? [[String: Any]] ?? []).first(where: { $0["sessionId"] as? String == id }) else { return nil }
        return chat(id, in: summary)
    }

    /// A `_acpmux/sessions` page (`{sessions: [summary], nextCursor}`), keeping only `peer`'s closed
    /// chats: a daemon from before the `peer`/`status` filters ignores them and pages everything. A
    /// chat's title is its own title when it has one, else the last part of its `<peer>/<name>` name.
    static func page(_ result: [String: Any], peer: String) -> Page {
        let chats: [Chat] = (result["sessions"] as? [[String: Any]] ?? []).compactMap { summary in
            guard let id = summary["sessionId"] as? String, !id.isEmpty,
                  summary["peer"] as? String == peer, summary["status"] as? String == "closed" else { return nil }
            let name = summary["name"] as? String ?? id
            let title = (summary["title"] as? String).flatMap { $0.isEmpty || $0 == name ? nil : $0 }
                ?? String(name.split(separator: "/").last ?? Substring(name))
            return Chat(id: id, title: title, harness: (summary["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return Page(chats: chats, next: (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}
