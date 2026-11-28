public import Foundation

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

extension ConversationClient {
    public func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.localConversations.rawValue])
        }
        return try await connection.request(request)
    }
}
