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

    /// One decoded `chat_changed` notification (decoded off the main actor).
    public enum Change: Sendable, Equatable {
        case removed(key: String)
        /// The live session's attention or latest reply changed: same place in the list.
        case activity(key: String, attention: String?, preview: String?)
        case upserted(key: String, chat: AcpmuxChat)
    }

    /// Decodes a `chat_changed` notification's params, or nil when malformed.
    public static func change(from params: [String: Any]) -> Change? {
        guard let key = params["key"] as? String, !key.isEmpty else { return nil }
        switch params["kind"] as? String {
        case "removed": return .removed(key: key)
        case "activity": return .activity(key: key, attention: params["attention"] as? String, preview: params["preview"] as? String)
        default:
            guard let chat = (params["chat"] as? [String: Any]).flatMap(AcpmuxChat.init(json:)) else { return nil }
            return .upserted(key: key, chat: chat)
        }
    }

    /// Applies a single `chat_changed` notification without re-sorting the full list.
    public mutating func apply(change: [String: Any]) {
        if let decoded = Self.change(from: change) { apply(decoded) }
    }

    /// Applies one decoded change without re-sorting the full list.
    public mutating func apply(_ change: Change) {
        switch change {
        case .removed(let key):
            values[key] = nil
            if let index = orderedKeys.firstIndex(of: key) { orderedKeys.remove(at: index) }
        case .activity(let key, let attention, let preview):
            values[key]?.attention = attention
            values[key]?.preview = preview
        case .upserted(let key, let chat):
            if values[key] != nil, let index = orderedKeys.firstIndex(of: key) { orderedKeys.remove(at: index) }
            values[key] = chat
            let insertion = Self.insertionIndex(chat, in: orderedKeys, values: values)
            orderedKeys.insert(key, at: insertion)
        }
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
