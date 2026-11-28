import Foundation

/// One chat in the sidebar's Recents, cut from acpmux's session summary.
public nonisolated struct AcpmuxRecentChat: Hashable, Sendable, Identifiable {
    /// What the row draws at its trailing edge, most urgent first (the pane's `sessionMark`).
    public enum Mark: Hashable, Sendable {
        case input
        case running
        case error
        case unread
    }

    public var id: String
    /// Nil for a chat with no prompt yet: the sidebar draws "New chat".
    public var title: String?
    public var harness: String
    public var cwd: String
    public var updatedAt: Double
    public var mark: Mark?

    public init(id: String, title: String?, harness: String, cwd: String = "", updatedAt: Double, mark: Mark? = nil) {
        self.id = id
        self.title = title
        self.harness = harness
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.mark = mark
    }
}

/// The local acpmux daemon's chats for Recents: a `_acpmux/watch` (or
/// `_acpmux/sessions`) result, kept current by `_acpmux/session_changed`.
/// The Home Chief's sessions are left out, as the quit census leaves them.
public nonisolated struct AcpmuxRecentChats: Sendable, Equatable {
    private var chats: [String: AcpmuxRecentChat] = [:]

    public init() {}

    /// Replaces every chat with the sessions of `result`.
    public mutating func reset(_ result: [String: Any]) {
        chats = [:]
        if let indexed = result["chats"] as? [[String: Any]] {
            for value in indexed {
                guard let chat = AcpmuxChat(json: value) else { continue }
                chats[chat.id] = AcpmuxRecentChat(id: chat.id, title: chat.title, harness: chat.harness,
                                                  cwd: chat.cwd ?? "", updatedAt: chat.updatedAt.timeIntervalSince1970 * 1000)
            }
            return
        }
        for summary in (result["sessions"] as? [Any] ?? []).compactMap({ $0 as? [String: Any] }) { upsert(summary) }
    }

    /// Applies one `_acpmux/session_changed`; a `purged` session leaves.
    public mutating func apply(changed params: [String: Any]) {
        if let key = params["key"] as? String, params["kind"] as? String == "removed" {
            chats[key] = nil
            return
        }
        guard let id = (params["sessionId"] as? String) ?? (params["key"] as? String) else { return }
        if params["kind"] as? String == "purged" {
            chats[id] = nil
        } else if let summary = (params["session"] as? [String: Any]) ?? (params["chat"] as? [String: Any]), let chat = AcpmuxChat(json: summary) {
            chats[chat.id] = AcpmuxRecentChat(id: chat.id, title: chat.title, harness: chat.harness,
                                               cwd: chat.cwd ?? "", updatedAt: chat.updatedAt.timeIntervalSince1970 * 1000)
        } else if let summary = params["session"] as? [String: Any] {
            upsert(summary)
        }
    }

    /// At most `limit` chats, newest activity first.
    public func newest(_ limit: Int) -> [AcpmuxRecentChat] {
        Array(chats.values.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }.prefix(limit))
    }

    private mutating func upsert(_ summary: [String: Any]) {
        guard let id = summary["sessionId"] as? String else { return }
        guard !AcpmuxSessionCensus.isChief(summary) else { chats[id] = nil; return }
        chats[id] = AcpmuxRecentChat(
            id: id, title: Self.title(summary), harness: summary["harness"] as? String ?? "", cwd: summary["cwd"] as? String ?? "",
            updatedAt: (summary["updatedAt"] as? NSNumber)?.doubleValue ?? 0, mark: Self.mark(summary))
    }

    /// The name the user gave, else the agent's title, else the first prompt
    /// (the pane's `sessionTitle`). acpmux names a session after its harness
    /// or family (`claude`, `claude-2`, `claude-fork`); such a name is not a title.
    static func title(_ summary: [String: Any]) -> String? {
        let name = summary["name"] as? String ?? ""
        let bare = name.split(separator: "/").last.map(String.init) ?? name
        func generated(from agent: String?) -> Bool {
            guard let agent, !agent.isEmpty, bare.hasPrefix(agent) else { return false }
            return isGeneratedSuffix(bare.dropFirst(agent.count))
        }
        if !name.isEmpty, !generated(from: summary["harness"] as? String), !generated(from: summary["family"] as? String) { return name }
        for key in ["title", "lastPrompt"] {
            if let text = (summary[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        }
        return nil
    }

    /// `(-fork|-N)*`: what acpmux appends to make a name unique or mark a fork.
    private static func isGeneratedSuffix(_ suffix: Substring) -> Bool {
        var rest = suffix
        while !rest.isEmpty {
            guard rest.first == "-" else { return false }
            rest = rest.dropFirst()
            if rest.hasPrefix("fork") {
                rest = rest.dropFirst(4)
            } else {
                let digits = rest.prefix { $0.isASCII && $0.isNumber }
                guard !digits.isEmpty else { return false }
                rest = rest.dropFirst(digits.count)
            }
        }
        return true
    }

    static func mark(_ summary: [String: Any]) -> AcpmuxRecentChat.Mark? {
        let status = summary["status"] as? String
        if ((summary["pendingPermissions"] as? NSNumber)?.intValue ?? 0) > 0 || status == "waiting" { return .input }
        if status == "running" { return .running }
        if status == "disconnected" || status == "unreachable" { return .error }
        if summary["unread"] as? Bool == true { return .unread }
        return nil
    }
}
