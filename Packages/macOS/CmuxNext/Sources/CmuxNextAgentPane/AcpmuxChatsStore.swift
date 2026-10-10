public import Foundation

/// The ordered mirror of `_acpmux/chats_watch`.
public nonisolated struct AcpmuxChatsStore: Sendable, Equatable {
    private var values: [String: AcpmuxChat] = [:]
    private var orderedKeys: [String] = []

    public init() {}

    public var chats: [AcpmuxChat] { orderedKeys.compactMap { values[$0] } }

    /// Replaces the mirror from a page response. Only the initial page is sorted.
    public mutating func reset(_ result: [String: Any]) {
        values.removeAll(keepingCapacity: true)
        orderedKeys.removeAll(keepingCapacity: true)
        for value in result["chats"] as? [[String: Any]] ?? [] {
            if let chat = AcpmuxChat(json: value) { values[chat.id] = chat }
        }
        orderedKeys = values.values.sorted(by: Self.isNewer).map(\.id)
    }

    /// Applies a single `chat_changed` notification without re-sorting the full list.
    public mutating func apply(change: [String: Any]) {
        let key = change["key"] as? String
        guard let key, !key.isEmpty else { return }
        if change["kind"] as? String == "removed" {
            values[key] = nil
            if let index = orderedKeys.firstIndex(of: key) { orderedKeys.remove(at: index) }
            return
        }
        guard let chat = (change["chat"] as? [String: Any]).flatMap(AcpmuxChat.init(json:)) else { return }
        if values[key] != nil, let index = orderedKeys.firstIndex(of: key) { orderedKeys.remove(at: index) }
        values[key] = chat
        let insertion = Self.insertionIndex(chat, in: orderedKeys, values: values)
        orderedKeys.insert(key, at: insertion)
    }

    public func filtered(query: String, grouping: AcpmuxChatGrouping? = nil) -> [AcpmuxChat] {
        chats.filter { chat in
            guard chat.matches(query) else { return false }
            if let grouping { return chat.groupValue(grouping) != nil }
            return true
        }
    }

    private static func isNewer(_ lhs: AcpmuxChat, _ rhs: AcpmuxChat) -> Bool {
        lhs.updatedAt > rhs.updatedAt || (lhs.updatedAt == rhs.updatedAt && lhs.id > rhs.id)
    }

    private static func insertionIndex(_ chat: AcpmuxChat, in keys: [String], values: [String: AcpmuxChat]) -> Int {
        var low = 0
        var high = keys.count
        while low < high {
            let middle = (low + high) / 2
            guard let current = values[keys[middle]] else { high = middle; continue }
            if isNewer(chat, current) { high = middle } else { low = middle + 1 }
        }
        return low
    }
}
