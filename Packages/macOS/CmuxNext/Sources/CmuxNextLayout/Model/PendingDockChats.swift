/// A pane's chats bound for a new chat dock (NewChatPlacement), never in its strip. Each is kept
/// under its provisional id and, once the store answers, its created id, so the dock finishing
/// under either id lets go of both. The store's alias from the provisional id goes when its tree
/// stops listing the provisional tab, often before the dock move ends; a provisional id found
/// only through that alias stayed pending, and every later Cmd-I in the pane waited for a chat
/// that had already docked (DockedAgentChat).
public nonisolated struct PendingDockChats: Equatable, Sendable {
    private var chats: [Chat] = []

    public init() {}

    private struct Chat: Equatable, Sendable {
        var provisional: String
        var created: String?
    }

    public var isEmpty: Bool { chats.isEmpty }

    /// Chat `provisional` opened hidden, on its way to its dock.
    public mutating func opened(_ provisional: String) {
        guard !chats.contains(where: { $0.provisional == provisional }) else { return }
        chats.append(Chat(provisional: provisional))
    }

    /// The store created chat `provisional` as `key`.
    public mutating func created(_ provisional: String, as key: String) {
        guard let index = chats.firstIndex(where: { $0.provisional == provisional }) else { return }
        chats[index].created = key
    }

    /// Chat `key` (either id) reached its dock, or will never get there.
    public mutating func finished(_ key: String, aliases: [String: String]) {
        chats.removeAll { $0.provisional == key || $0.created == key || aliases[$0.provisional] == key }
    }

    /// The tab ids to keep out of the strip: a provisional id also hides the tab the store
    /// replaced it with, from the store's first snapshot on (`aliases`).
    public func hidden(aliases: [String: String]) -> Set<String> {
        var ids: Set<String> = []
        for chat in chats {
            ids.insert(chat.provisional)
            if let created = chat.created { ids.insert(created) }
            if let alias = aliases[chat.provisional] { ids.insert(alias) }
        }
        return ids
    }
}
