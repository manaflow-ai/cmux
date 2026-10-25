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
        return Self.page(result)
    }

    /// A `_acpmux/sessions` page (`{sessions: [summary], nextCursor}`). A chat's title is its own
    /// title when it has one, else the last part of its `<peer>/<name>` name.
    static func page(_ result: [String: Any]) -> Page {
        let chats: [Chat] = (result["sessions"] as? [[String: Any]] ?? []).compactMap { summary in
            guard let id = summary["sessionId"] as? String, !id.isEmpty else { return nil }
            let name = summary["name"] as? String ?? id
            let title = (summary["title"] as? String).flatMap { $0.isEmpty || $0 == name ? nil : $0 }
                ?? String(name.split(separator: "/").last ?? Substring(name))
            return Chat(id: id, title: title, harness: (summary["harness"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return Page(chats: chats, next: (result["nextCursor"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}
