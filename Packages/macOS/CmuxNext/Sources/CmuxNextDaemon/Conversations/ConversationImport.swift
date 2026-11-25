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

extension ConversationClient {
    public func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.localConversations.rawValue])
        }
        return try await connection.request(request)
    }
}
