import Foundation

/// Serves `chat.list` to apps on the verified-app provider channel: every agent chat on every
/// machine, in the Priority view's rank order, as
/// `{chats: [{id, title, project, machine, state, unread, pinned}]}`. Read-only; other `chat.*`
/// ops stay `operation.unsupported`.
public nonisolated struct ChatListHandler: AppHostCapabilityHandler {
    private let chats: @MainActor @Sendable () -> [AppChatSummary]

    /// The capability family supplied on the verified-app provider channel.
    public var families: Set<String> { ["chat"] }

    /// - Parameter chats: The ranked chats now; read at each call.
    public init(chats: @escaping @MainActor @Sendable () -> [AppChatSummary]) {
        self.chats = chats
    }

    /// Answers `chat.list`.
    /// - Parameter request: The supervisor-admitted call.
    /// - Returns: `{chats: [...]}` in rank order.
    /// - Throws: `operation.unsupported` for any other op.
    public func handle(_ request: AppHostCapabilityRequest) async throws(AppHostCapabilityError) -> AppJSON {
        guard request.op == "chat.list" else { throw .unsupported(request.op) }
        let rows = await chats()
        return ["chats": .array(rows.map(Self.json))]
    }

    private static func json(_ chat: AppChatSummary) -> AppJSON {
        .object([
            "id": .string(chat.id),
            "title": .string(chat.title),
            "project": chat.project.map(AppJSON.string) ?? .null,
            "machine": chat.machine.map(AppJSON.string) ?? .null,
            "state": .string(chat.state.rawValue),
            "unread": .bool(chat.unread),
            "pinned": .bool(chat.pinned),
        ])
    }
}
