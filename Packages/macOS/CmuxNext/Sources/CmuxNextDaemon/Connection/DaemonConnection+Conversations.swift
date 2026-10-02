public import Foundation

/// Local conversations (`local-conversations-v1`, plans/cmux-next/home.md).
/// The daemon's conversation owner is the single writer; each wrapper throws
/// `missingCapabilities` on a daemon without it.
extension DaemonConnection {
    public var supportsLocalConversations: Bool {
        identity?.supports(DaemonCapabilities.shared.localConversations) == true
    }

    private func requireLocalConversations() throws {
        guard supportsLocalConversations else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.localConversations])
        }
    }

    public func listConversations() async throws -> [ConversationSummary] {
        try requireLocalConversations()
        return try await request(ListConversationsRequest()).conversations
    }

    public func createConversation(_ request: CreateConversationRequest) async throws -> ConversationCreated {
        try requireLocalConversations()
        return try await self.request(request)
    }

    public func conversationSnapshot(_ conversation: String, tail: Int) async throws -> ConversationSnapshot {
        try requireLocalConversations()
        return try await request(ConversationSnapshotRequest(conversation: conversation, tail: tail))
    }

    public func conversationHistory(_ conversation: String, before seq: UInt64, limit: Int) async throws -> [ConversationMessage] {
        try requireLocalConversations()
        return try await request(ConversationHistoryRequest(conversation: conversation, beforeSeq: seq, limit: limit)).messages
    }

    public func conversationOp(_ request: ConversationOpRequest) async throws -> ConversationOpResult {
        try requireLocalConversations()
        return try await self.request(request)
    }

    public func conversationTyping(_ conversation: String, actor: String, on: Bool) async throws {
        try requireLocalConversations()
        _ = try await request(ConversationTypingRequest(conversation: conversation, actor: actor, on: on))
    }
}
