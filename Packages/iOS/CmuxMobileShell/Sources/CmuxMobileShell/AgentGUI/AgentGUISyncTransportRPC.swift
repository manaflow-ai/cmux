public import CmuxAgentSync
public import CmuxAgentWire
public import CmuxMobileRPC
public import Foundation

/// Bridges agent GUI sync requests and events onto a paired Mac RPC client.
public actor AgentGUISyncTransportRPC: AgentSyncTransport {
    /// Connection lifecycle events supplied by the mobile shell composite.
    public nonisolated let connectionEvents: AsyncStream<AgentSyncConnectionEvent>

    private let client: MobileCoreRPCClient
    private let streamID: String
    private var currentTopics: Set<String>

    /// Creates an RPC-backed agent GUI transport.
    /// - Parameters:
    ///   - client: The paired Mac RPC client for the foreground connection.
    ///   - streamID: The server-side mobile event stream identifier.
    ///   - connectionEvents: Lifecycle events for this connection generation.
    public init(
        client: MobileCoreRPCClient,
        streamID: String,
        connectionEvents: AsyncStream<AgentSyncConnectionEvent>
    ) {
        self.client = client
        self.streamID = streamID
        self.connectionEvents = connectionEvents
        currentTopics = []
    }

    /// Sends one `gui.v1` request while preserving its raw JSON parameters.
    /// - Parameters:
    ///   - method: The GUI wire method name.
    ///   - params: Raw JSON parameters encoded by `CmuxAgentWire`.
    /// - Returns: The raw JSON result payload.
    public func request(method: String, params: Data) async throws -> Data {
        do {
            return try await client.sendRequest(Self.requestData(method: method, params: params))
        } catch let error as MobileShellConnectionError {
            if case .rpcError(let code, let message) = error {
                throw GuiWireError(code: code ?? GuiWireErrorCode.internalError.rawValue, message: message)
            }
            throw error
        }
    }

    /// Registers GUI event topics before exposing their filtered event stream.
    /// - Parameter topics: Requested `gui.v1` topics.
    /// - Returns: A stream of raw agent sync frames.
    public func subscribe(topics: [String]) async throws -> AsyncStream<AgentSyncFrame> {
        let filteredTopics = Self.filteredTopics(topics)
        guard !filteredTopics.isEmpty else {
            if !currentTopics.isEmpty {
                try await removeServerSubscription()
            }
            return AsyncStream { continuation in continuation.finish() }
        }

        // Install the local listener first so events emitted during the server
        // acknowledgement cannot fall between listener creation and the pull.
        let topicSet = Set(filteredTopics)
        let source = await client.subscribe(to: topicSet)
        let pair = AsyncStream<AgentSyncFrame>.makeStream(bufferingPolicy: .bufferingNewest(256))
        let expectedStreamID = streamID
        let forwardingTask = Task {
            for await envelope in source {
                guard !Task.isCancelled else { break }
                guard topicSet.contains(envelope.topic),
                      envelope.streamID == nil || envelope.streamID == expectedStreamID,
                      let payload = envelope.payloadJSON else {
                    continue
                }
                pair.continuation.yield(AgentSyncFrame(topic: envelope.topic, payload: payload))
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in forwardingTask.cancel() }

        do {
            try await replaceServerSubscription(with: topicSet)
            return pair.stream
        } catch {
            // Cancelling iteration terminates MobileCoreRPCClient's local
            // listener, so a failed server acknowledgement cannot orphan it.
            forwardingTask.cancel()
            pair.continuation.finish()
            throw error
        }
    }

    /// Removes GUI topics by replacing the server's full per-stream registration.
    /// - Parameter topics: GUI topics to remove.
    public func unsubscribe(topics: [String]) async {
        let removedTopics = Set(Self.filteredTopics(topics))
        guard !removedTopics.isEmpty else { return }
        let remainingTopics = currentTopics.subtracting(removedTopics)
        guard remainingTopics != currentTopics else { return }

        if remainingTopics.isEmpty {
            try? await removeServerSubscription()
        } else {
            try? await replaceServerSubscription(with: remainingTopics)
        }
    }

    private static func requestData(method: String, params: Data) throws -> Data {
        let rawParams = try JSONSerialization.jsonObject(with: params, options: [.fragmentsAllowed])
        return try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "method": method,
            "params": rawParams,
        ])
    }

    private static func filteredTopics(_ topics: [String]) -> [String] {
        Array(Set(topics.filter { $0.hasPrefix("gui.v1.") })).sorted()
    }

    private func replaceServerSubscription(with topics: Set<String>) async throws {
        let acknowledgement = try await client.sendRequest(
            MobileCoreRPCClient.requestData(
                method: "mobile.events.subscribe",
                params: [
                    "stream_id": streamID,
                    "topics": topics.sorted(),
                ]
            )
        )
        let response = try MobileEventSubscribeResponse.decode(acknowledgement)
        guard response.streamID == streamID else {
            throw GuiWireError(
                code: .internalError,
                message: "Invalid agent GUI event subscription acknowledgement"
            )
        }
        currentTopics = topics
    }

    private func removeServerSubscription() async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.events.unsubscribe",
            params: ["stream_id": streamID]
        )
        _ = try await client.sendRequest(request)
        currentTopics = []
    }
}
