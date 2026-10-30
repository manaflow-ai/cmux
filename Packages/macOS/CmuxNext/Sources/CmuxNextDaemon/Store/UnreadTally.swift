/// One record's unread count: its tabs with an unread notification, and the conversation ids of
/// the unread conversation tabs among them. Each pane, screen and workspace keeps its own, counted
/// again from its children only when one of them changed.
struct UnreadTally: Equatable {
    /// What one tab adds.
    enum Mark: Equatable {
        case none
        /// An unread notification; `conversation` for a conversation tab.
        case unread(conversation: String?)
    }

    var tabs = 0
    var conversations: [String: Int] = [:]

    mutating func add(_ mark: Mark) {
        guard case .unread(let conversation) = mark else { return }
        tabs += 1
        if let conversation { conversations[conversation, default: 0] += 1 }
    }

    mutating func add(_ other: UnreadTally) {
        tabs += other.tabs
        for (id, count) in other.conversations { conversations[id, default: 0] += count }
    }
}
