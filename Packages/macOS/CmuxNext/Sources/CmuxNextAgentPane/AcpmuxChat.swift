public import Foundation

/// One metadata-only chat from acpmux's device-wide index.
public nonisolated struct AcpmuxChat: Hashable, Sendable, Identifiable {
    public let id: String
    public let sessionID: String
    public let harness: String
    public let title: String?
    public let cwd: String?
    public let createdAt: Date?
    public let updatedAt: Date
    public let messageCount: Int?
    public let accounts: [String]
    public let roots: [String]
    public let sourcePath: String?
    /// The agent mark id acpmux resolved for the chat's harness (design/agent-icons), nil
    /// when it has none or the daemon predates it.
    public let brand: String?
    /// What the live acpmux session continuing this chat needs from the
    /// person (`needsInput`, `failed`, `unread`), nil when nothing.
    public var attention: String?
    /// That session's latest reply, one line; nil without a live session.
    public var preview: String?
    /// The chat whose agent started this one (acpmux `parent`): it folds under that chat and is
    /// never listed on its own (Leo 2026-10-13).
    public var parent: String?
    /// What a query window found in the chat's prompts and answers (acpmux `match`, `chats/text.rs`);
    /// nil for a chat found by its title or listed without a query.
    public var said: Said?

    /// A message of the chat that holds every word of the query: its turn (`_acpmux/chat_transcript`'s
    /// turns), whether it is the prompt or the answer, a short snippet of it, the snippet's characters
    /// (Unicode scalar offsets) that are part of a word, and how many of the chat's messages hold them.
    public nonisolated struct Said: Hashable, Sendable {
        public let turn: Int
        public let isAnswer: Bool
        public let snippet: String
        public let highlights: [Int]
        public let matches: Int

        public init(turn: Int, isAnswer: Bool, snippet: String, highlights: [Int] = [], matches: Int = 1) {
            (self.turn, self.isAnswer, self.snippet, self.highlights, self.matches) = (turn, isAnswer, snippet, highlights, matches)
        }

        init?(json: [String: Any]?) {
            guard let json, let snippet = json["snippet"] as? String, let turn = (json["turn"] as? NSNumber)?.intValue else { return nil }
            self.init(turn: turn, isAnswer: json["role"] as? String == "answer", snippet: snippet,
                      highlights: (json["highlights"] as? [NSNumber] ?? []).map(\.intValue),
                      matches: (json["matches"] as? NSNumber)?.intValue ?? 1)
        }
    }

    public init(id: String, sessionID: String, harness: String, title: String? = nil, cwd: String? = nil,
                createdAt: Date? = nil, updatedAt: Date, messageCount: Int? = nil, accounts: [String] = [],
                roots: [String] = [], sourcePath: String? = nil, brand: String? = nil, attention: String? = nil,
                preview: String? = nil, parent: String? = nil, said: Said? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.harness = harness
        self.title = title
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.accounts = accounts
        self.roots = roots
        self.sourcePath = sourcePath
        self.brand = brand
        self.attention = attention
        self.preview = preview
        self.parent = parent
        self.said = said
    }

    /// Decodes the daemon's `chat_value` object. Unknown optional fields are ignored.
    public init?(json: [String: Any]) {
        guard let id = json["key"] as? String, !id.isEmpty,
              let sessionID = json["sessionId"] as? String, !sessionID.isEmpty,
              let harness = json["harness"] as? String, !harness.isEmpty else { return nil }
        let updated = Self.milliseconds(json["updatedMs"] ?? json["updatedAt"]) ?? 0
        let created = Self.milliseconds(json["createdMs"] ?? json["createdAt"])
        self.init(id: id, sessionID: sessionID, harness: harness,
                  title: (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  cwd: (json["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  createdAt: created.map { Date(timeIntervalSince1970: $0 / 1000) },
                  updatedAt: Date(timeIntervalSince1970: updated / 1000),
                  messageCount: (json["messageCount"] as? NSNumber).map { $0.intValue },
                  accounts: json["accounts"] as? [String] ?? [], roots: json["roots"] as? [String] ?? [],
                  sourcePath: json["sourcePath"] as? String, brand: json["brand"] as? String,
                  attention: json["attention"] as? String, preview: json["preview"] as? String,
                  parent: (json["parent"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  said: Said(json: json["match"] as? [String: Any]))
    }

    private static func milliseconds(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        return value.doubleValue
    }

    /// Values used by the grouping menu and by the search index.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let fields: [String?] = [title, id, sessionID, harness, cwd, accounts.joined(separator: " "), roots.joined(separator: " ")]
        return fields.compactMap { $0?.localizedLowercase }.contains { $0.localizedStandardRange(of: query.localizedLowercase) != nil }
    }

    /// A stable group label; nil means the record has no value for this grouping.
    public func groupValue(_ grouping: AcpmuxChatGrouping) -> String? {
        switch grouping {
        case .harness: return harness
        case .folder: return cwd
        case .account: return accounts.first
        }
    }
}
