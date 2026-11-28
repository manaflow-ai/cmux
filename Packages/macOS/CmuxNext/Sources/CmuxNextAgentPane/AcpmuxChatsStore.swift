public import Foundation

/// The ordered mirror of `_acpmux/chats_watch`.
public nonisolated struct AcpmuxChatsStore: Sendable, Equatable {
    private var values: [String: AcpmuxChat] = [:]
    private var orderedKeys: [String] = []

    public init() {}

    /// Every chat, newest first. O(n): only for readers that need the whole
    /// list (the palette's chats page, the projects relay off the main actor);
    /// per-change readers use `count`, `chat(id:)` and `newest(_:)`.
    public var chats: [AcpmuxChat] { orderedKeys.compactMap { values[$0] }.filter { $0.parent == nil } }

    public var count: Int { orderedKeys.count }

    /// One chat by key, O(1).
    public func chat(id: String) -> AcpmuxChat? { values[id] }

    /// The newest `limit` chats, a child chat (`parent`) left out: O(limit + children passed).
    public func newest(_ limit: Int) -> [AcpmuxChat] {
        var shown: [AcpmuxChat] = []
        for key in orderedKeys where shown.count < limit {
            if let chat = values[key], chat.parent == nil { shown.append(chat) }
        }
        return shown
    }

    /// Replaces the mirror from a page response. acpmux sends the page sorted, newest first:
    /// its order is kept after one O(n) check (an older daemon's page is sorted here).
    public mutating func reset(_ result: [String: Any]) {
        values.removeAll(keepingCapacity: true)
        orderedKeys.removeAll(keepingCapacity: true)
        for value in result["chats"] as? [[String: Any]] ?? [] {
            guard let chat = AcpmuxChat(json: value), values.updateValue(chat, forKey: chat.id) == nil else { continue }
            orderedKeys.append(chat.id)
        }
        let sorted = zip(orderedKeys, orderedKeys.dropFirst()).allSatisfy { pair in
            guard let newer = values[pair.0], let older = values[pair.1] else { return false }
            return Self.isNewer(newer, older)
        }
        if !sorted { orderedKeys = values.values.sorted(by: Self.isNewer).map(\.id) }
    }

    /// One decoded `chat_changed` notification (decoded off the main actor).
    public enum Change: Sendable, Equatable {
        case removed(key: String)
        /// The live session's attention or latest reply changed: same place in the list.
        case activity(key: String, attention: String?, preview: String?, parent: String?)
        case upserted(key: String, chat: AcpmuxChat)
    }

    /// Decodes a `chat_changed` notification's params, or nil when malformed.
    public static func change(from params: [String: Any]) -> Change? {
        guard let key = params["key"] as? String, !key.isEmpty else { return nil }
        switch params["kind"] as? String {
        case "removed": return .removed(key: key)
        case "activity":
            return .activity(key: key, attention: params["attention"] as? String, preview: params["preview"] as? String,
                             parent: (params["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 })
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
            if let old = values[key] {
                removeKey(of: old)
                values[key] = nil
            }
        case .activity(let key, let attention, let preview, let parent):
            values[key]?.attention = attention
            values[key]?.preview = preview
            values[key]?.parent = parent
        case .upserted(let key, let chat):
            if let old = values[key] { removeKey(of: old) }
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

    /// acpmux's order (`ChatIndex::chats`): newest first, then the key ascending.
    private static func isNewer(_ lhs: AcpmuxChat, _ rhs: AcpmuxChat) -> Bool {
        lhs.updatedAt > rhs.updatedAt || (lhs.updatedAt == rhs.updatedAt && lhs.id < rhs.id)
    }

    /// Drops `chat`'s key from the order: a binary search on its sort key
    /// (updatedAt, id is a total order), not a scan of every key.
    /// `values` must still hold `chat` under its key.
    private mutating func removeKey(of chat: AcpmuxChat) {
        var low = 0
        var high = orderedKeys.count
        while low < high {
            let middle = (low + high) / 2
            if let current = values[orderedKeys[middle]], Self.isNewer(current, chat) { low = middle + 1 } else { high = middle }
        }
        let index = low
        if index < orderedKeys.count, orderedKeys[index] == chat.id {
            orderedKeys.remove(at: index)
        } else if let index = orderedKeys.firstIndex(of: chat.id) {
            orderedKeys.remove(at: index)
        }
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
