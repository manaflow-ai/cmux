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

    public init(id: String, sessionID: String, harness: String, title: String? = nil, cwd: String? = nil,
                createdAt: Date? = nil, updatedAt: Date, messageCount: Int? = nil, accounts: [String] = [],
                roots: [String] = [], sourcePath: String? = nil) {
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
                  sourcePath: json["sourcePath"] as? String)
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
