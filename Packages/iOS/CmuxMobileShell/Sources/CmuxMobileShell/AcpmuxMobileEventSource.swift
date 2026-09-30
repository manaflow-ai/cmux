public import CMUXMobileCore
public import CmuxAgentChat
public import CmuxMobileRPC
public import Foundation

/// Mobile adapter for the acpmux-backed conversation surface.
///
/// The phone never knows how acpmux is reached. The paired Mac owns the daemon
/// connection and republishes the same backend-neutral ``ChatSessionEvent``
/// values used by the transcript backend. A future provider can implement the
/// same ``ChatEventSource`` contract without changing the UI or store.
public actor AcpmuxMobileEventSource: ChatEventSource {
    public nonisolated let supportsArtifacts = false
    public nonisolated let supportsArtifactFolders = false

    private let client: MobileCoreRPCClient
    private let coding = ChatWireCoding()
    private let eventTopic = "acpmux.chat.message"

    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    public func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        var params: [String: Any] = [:]
        if let workspaceID { params["workspace_id"] = workspaceID }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.sessions",
            params: params
        )
        let data = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionsResponse.self, from: data).sessions
    }

    public func session(sessionID: String) async throws -> ChatSessionDescriptor {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.session",
            params: ["session_id": sessionID]
        )
        let data = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionResponse.self, from: data).session
    }

    public func createSession(harness: String?, workingDirectory: String?) async throws -> String {
        var params: [String: Any] = [:]
        if let harness { params["harness"] = harness }
        if let workingDirectory { params["cwd"] = workingDirectory }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.session.new",
            params: params
        )
        let data = try await client.sendRequest(request)
        return try coding.decode(SessionIDResponse.self, from: data).sessionID
    }

    public func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        var params: [String: Any] = [
            "session_id": sessionID,
            "limit": limit,
        ]
        if let beforeSeq { params["before_seq"] = beforeSeq }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.history",
            params: params
        )
        let data = try await client.sendRequest(request)
        return try coding.decode(ChatHistoryPage.self, from: data)
    }

    public func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let envelopes = await client.subscribe(to: [eventTopic])
        let client = self.client
        let coding = self.coding
        let topic = eventTopic
        let streamID = UUID().uuidString
        return AsyncStream { continuation in
            let pump = Task {
                do {
                    let request = try MobileCoreRPCClient.requestData(
                        method: "mobile.events.subscribe",
                        params: ["topics": [topic], "stream_id": streamID]
                    )
                    _ = try await client.sendRequest(request)
                } catch {
                    continuation.finish()
                    return
                }

                for await envelope in envelopes {
                    guard let payload = envelope.payloadJSON,
                          let frame = try? coding.decode(ChatSessionEventFrame.self, from: payload),
                          frame.sessionID == sessionID else { continue }
                    continuation.yield(frame.event)
                }
                continuation.finish()
            }

            continuation.onTermination = { reason in
                pump.cancel()
                guard case .cancelled = reason else { return }
                Task {
                    guard let request = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) else { return }
                    _ = try? await client.sendRequest(request)
                }
            }
        }
    }

    public func send(
        text: String,
        attachments: [ChatOutboundAttachment],
        sessionID: String
    ) async throws {
        // The initial acpmux bridge intentionally rejects attachments. Keeping
        // the check here prevents silently dropping a future attachment from
        // a provider-neutral composer.
        guard attachments.isEmpty else { throw ChatEventSourceError.unsupported }
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.send",
            params: ["session_id": sessionID, "text": text]
        )
        _ = try await client.sendRequest(request)
    }

    public func interrupt(sessionID: String, hard _: Bool) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.cancel",
            params: ["session_id": sessionID]
        )
        _ = try await client.sendRequest(request)
    }

    public func answer(optionIndex: Int, sessionID: String) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.acpmux.answer",
            params: ["session_id": sessionID, "option_index": optionIndex]
        )
        _ = try await client.sendRequest(request)
    }
}

private struct SessionIDResponse: Codable, Sendable {
    let sessionID: String

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}
