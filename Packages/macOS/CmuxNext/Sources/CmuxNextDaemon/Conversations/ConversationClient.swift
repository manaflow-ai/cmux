public import Foundation

/// Local conversations (`local-conversations-v1`, plans/cmux-next/home.md)
/// over one daemon connection. The daemon's conversation owner is the single
/// writer; each call throws `missingCapabilities` on a daemon without it.
public struct ConversationClient: Sendable {
    public let connection: DaemonConnection

    public init(_ connection: DaemonConnection) {
        self.connection = connection
    }

    public static func supported(by connection: DaemonConnection) async -> Bool {
        await connection.identity?.supports(DaemonCapabilities.shared.localConversations) == true
    }

    private func require() async throws {
        guard await Self.supported(by: connection) else {
            throw DaemonError.missingCapabilities([DaemonCapabilities.shared.localConversations])
        }
    }

    public func list() async throws -> [ConversationSummary] {
        try await require()
        return try await connection.request(ListConversationsRequest()).conversations
    }

    public func create(_ request: CreateConversationRequest) async throws -> ConversationCreated {
        try await require()
        return try await connection.request(request)
    }

    public func snapshot(_ conversation: String, tail: Int) async throws -> ConversationSnapshot {
        try await require()
        return try await connection.request(ConversationSnapshotRequest(conversation: conversation, tail: tail))
    }

    public func history(_ conversation: String, before seq: UInt64, limit: Int) async throws -> [ConversationMessage] {
        try await require()
        return try await connection.request(ConversationHistoryRequest(conversation: conversation, beforeSeq: seq, limit: limit)).messages
    }

    public func op(_ request: ConversationOpRequest) async throws -> ConversationOpResult {
        try await require()
        return try await connection.request(request)
    }

    public func typing(_ conversation: String, actor: String, on: Bool) async throws {
        try await require()
        _ = try await connection.request(ConversationTypingRequest(conversation: conversation, actor: actor, on: on))
    }
}
