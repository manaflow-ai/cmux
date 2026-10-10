public import Foundation

/// One page request of the New Tab page's All chats list (`chats.page {query?, cursor?, limit?}`,
/// cx-n0i9): the page asks for the rows near its viewport, the host asks the daemon
/// (`_acpmux/chats`, unix socket) and answers with that page only. The list never holds the
/// whole device index, and the main actor never maps it.
public nonisolated struct AgentPaneChatsQuery: Hashable, Sendable {
    public var text: String?
    /// The daemon's `nextCursor` of the previous page; nil for the first page.
    public var cursor: String?
    public var limit: Int

    public static let maximumLimit = 200

    public init(text: String?, cursor: String?, limit: Int) {
        self.text = text
        self.cursor = cursor
        self.limit = min(max(limit, 1), Self.maximumLimit)
    }

    init(params: [String: Any]?) {
        let text = (params?["query"] as? String).map { String($0.prefix(512)) }
        let cursor = (params?["cursor"] as? String).map { String($0.prefix(32)) }
        self.init(text: text?.isEmpty == true ? nil : text, cursor: cursor,
                  limit: (params?["limit"] as? NSNumber)?.intValue ?? 50)
    }
}

/// One page of chats, newest first, as the host answers `chats.page`.
public nonisolated struct AgentPaneChatsPage: Sendable {
    public var chats: [AcpmuxChat]
    public var nextCursor: String?
    public var ready: Bool
    public var enabled: Bool
    /// The row design (TEMPORARY design picker `sidebar.allChats.design`: quiet, age, project).
    public var design: String

    public init(chats: [AcpmuxChat], nextCursor: String?, ready: Bool, enabled: Bool, design: String = "age") {
        self.chats = chats
        self.nextCursor = nextCursor
        self.ready = ready
        self.enabled = enabled
        self.design = design
    }

    /// Decodes the daemon's `_acpmux/chats` result.
    init(result: [String: Any]) {
        let rows = result["chats"] as? [[String: Any]] ?? []
        let next: String? = switch result["nextCursor"] {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: nil
        }
        self.init(chats: rows.compactMap(AcpmuxChat.init(json:)), nextCursor: next,
                  ready: result["ready"] as? Bool ?? false, enabled: result["enabled"] as? Bool ?? true)
    }

    var reply: [String: Any] {
        var reply: [String: Any] = [
            "ready": ready, "enabled": enabled, "design": design,
            "chats": chats.map { chat -> [String: Any] in
                var row: [String: Any] = ["key": chat.id, "harness": chat.harness,
                                          "updatedAt": (chat.updatedAt.timeIntervalSince1970 * 1000).rounded()]
                if let title = chat.title { row["title"] = title }
                if let cwd = chat.cwd { row["cwd"] = cwd }
                return row
            },
        ]
        if let nextCursor { reply["nextCursor"] = nextCursor }
        return reply
    }
}

extension AcpmuxStatusClient {
    /// `_acpmux/chats`: one page of the device-wide chat index. The socket exchange and the JSON
    /// decode run off the caller's actor.
    @concurrent static func chatsPage(socketPath: String, query: AgentPaneChatsQuery,
                                      deadline: Duration = .seconds(3)) async throws -> AgentPaneChatsPage {
        var params: [String: any Sendable] = ["limit": query.limit]
        if let text = query.text { params["query"] = text }
        if let cursor = query.cursor { params["cursor"] = cursor }
        let result = try await call(socketPath: socketPath, method: "_acpmux/chats", params: params, deadline: deadline)
        return AgentPaneChatsPage(result: result)
    }
}

extension AcpmuxEnvironment {
    /// One page of this daemon's device-wide chat index (`chats.page`, cx-n0i9).
    public nonisolated func chatsPage(_ query: AgentPaneChatsQuery) async throws -> AgentPaneChatsPage {
        try await AcpmuxStatusClient.chatsPage(socketPath: socketPath, query: query)
    }
}

extension AgentPaneModel {
    func respondToChatsPage(_ query: AgentPaneChatsQuery) async -> [String: Any] {
        guard let onChatsPage else { return Self.unsupported("chats.page") }
        guard let page = await onChatsPage(query) else { return AgentPaneReply.failure(code: "chats.unavailable", message: "chats.unavailable") }
        return AgentPaneReply.success(page.reply)
    }
}
