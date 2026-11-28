public import Foundation

extension ConversationClient {
    public func importHistory(_ request: ConversationImportRequest) async throws -> ConversationImportResult {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapability.localConversations.rawValue])
        }
        return try await connection.request(request)
    }
}
