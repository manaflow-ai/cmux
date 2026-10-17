import Foundation

/// Carries the conversation protocol over the existing account-authorized channel.
/// Notification frames contain cursors only; transcript content is read by replay.
struct MobileConversationRPC: Sendable {
    let connection: any MobileSyncing
    func call<Payload: Encodable & Sendable, Reply: Decodable & Sendable>(
        _ operation: String,
        workspaceID: String,
        payload: Payload,
        as: Reply.Type = Reply.self
    ) async throws -> Reply {
        let frame = ConversationFrame(
            id: UUID().uuidString,
            method: "mobile.conversation.\(operation)",
            params: ConversationParameters(workspaceID: workspaceID, payload: payload)
        )
        let reply = try await connection.sendRequest(
            JSONEncoder().encode(frame),
            timeoutNanoseconds: nil
        )
        return try JSONDecoder().decode(ConversationResponse<Reply>.self, from: reply).value
    }

    /// Installs the local listener before awaiting the remote subscription ACK.
    /// The first nil value is a barrier: a replay after it closes the subscribe gap.
    func changes() async -> AsyncThrowingStream<Data?, any Error> {
        let notifications = await connection.subscribe(to: [Self.topic])
        // A connection owns one idempotent registration. Opening another task
        // replaces it; transport teardown retires it. Navigation never issues
        // a cleanup RPC which could redial an already disconnected host.
        let streamID = "mobile-conversation-v1"
        let connection = connection
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let frame = SubscriptionFrame(
                        id: UUID().uuidString,
                        method: "mobile.events.subscribe",
                        params: SubscriptionParameters(streamID: streamID, topics: [Self.topic])
                    )
                    _ = try await connection.sendRequest(
                        JSONEncoder().encode(frame),
                        timeoutNanoseconds: nil
                    )
                    continuation.yield(nil)
                    for await notification in notifications {
                        try Task.checkCancellation()
                        continuation.yield(notification.payloadJSON)
                    }
                    throw MobileConversationTransportError.disconnected
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private static let topic = "mobile.conversation.changed"

    private struct ConversationResponse<Value: Decodable>: Decodable {
        let value: Value
    }

    private struct ConversationFrame<Payload: Encodable & Sendable>: Encodable, Sendable {
        let id: String
        let method: String
        let params: ConversationParameters<Payload>
    }

    private struct ConversationParameters<Payload: Encodable & Sendable>: Encodable, Sendable {
        let workspaceID: String
        let payload: Payload

        enum CodingKeys: String, CodingKey {
            case workspaceID = "workspace_id"
            case payload
        }
    }

    private struct SubscriptionFrame: Encodable, Sendable {
        let id: String
        let method: String
        let params: SubscriptionParameters
    }

    private struct SubscriptionParameters: Encodable, Sendable {
        let streamID: String
        let topics: [String]

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case topics
        }
    }
}
