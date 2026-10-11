public import Foundation

/// One message of a history import: its own id, client id, author, parts
/// (as the owner stores them) and time (`YYYY-MM-DDTHH:MM:SS.mmmZ`).
public struct ConversationImportedMessage: Encodable, Sendable, Hashable {
    public var id: String?
    public var clientMsgID: String
    public var author: String
    public var parts: [JSONValue]
    public var createdAt: String

    public init(id: String?, clientMsgID: String, author: String, parts: [JSONValue], createdAt: String) {
        self.id = id
        self.clientMsgID = clientMsgID
        self.author = author
        self.parts = parts
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, author, parts
        case clientMsgID = "client_msg_id"
        case createdAt = "created_at"
    }
}

/// `conversation-import` (cmux-tui conversation_import.rs): appends history
/// from another store once, keeping authors and times; the owner assigns
/// seqs and skips what it already holds. Local user connections only.
public struct ConversationImportRequest: DaemonRequest {
    public typealias Response = ConversationImportResult
    public static let command = "conversation-import"
    public var conversation: String
    public var messages: [ConversationImportedMessage]

    public init(conversation: String, messages: [ConversationImportedMessage]) {
        self.conversation = conversation
        self.messages = messages
    }
}

public struct ConversationImportResult: Decodable, Sendable, Equatable {
    public var conversation: ConversationSummary
    /// The seqs the imported messages got.
    public var imported: [UInt64]
    /// Messages the conversation already held.
    public var skipped: Int

    public init(conversation: ConversationSummary, imported: [UInt64], skipped: Int) {
        self.conversation = conversation
        self.imported = imported
        self.skipped = skipped
    }
}

extension ConversationClient {
    public func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.localConversations])
        }
        return try await connection.request(request)
    }
}
