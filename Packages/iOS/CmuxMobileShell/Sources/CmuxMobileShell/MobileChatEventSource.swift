public import CmuxAgentChat
public import CmuxMobileRPC
import Foundation

/// The iOS implementation of ``CmuxAgentChat/ChatEventSource``: adapts the
/// mobile RPC client to the chat domain seam.
///
/// History and actions go through `mobile.chat.*` request methods; live
/// updates arrive on the `chat.message` event topic, filtered per session.
/// The returned event stream finishes when the underlying connection drops;
/// ``CmuxAgentChat/ChatConversationStore`` resubscribes through its `run()`
/// loop.
public actor MobileChatEventSource: ChatEventSource {
    private let client: MobileCoreRPCClient
    private let coding = ChatWireCoding()

    /// Creates the adapter.
    ///
    /// - Parameter client: The connected RPC client for the paired Mac.
    public init(client: MobileCoreRPCClient) {
        self.client = client
    }

    /// Lists chat-capable agent sessions the Mac knows about.
    ///
    /// Not part of ``CmuxAgentChat/ChatEventSource`` (which is scoped to one
    /// conversation); hosts call this to build the session list.
    ///
    /// - Parameter workspaceID: Restrict to one workspace, or `nil` for all.
    /// - Returns: Sessions ordered by the host (most recent activity first).
    public func sessions(workspaceID: String?) async throws -> [ChatSessionDescriptor] {
        var params: [String: Any] = [:]
        if let workspaceID {
            params["workspace_id"] = workspaceID
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.sessions", params: params)
        let result = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionsResponse.self, from: result).sessions
    }

    /// Pulls the authoritative snapshot of one session by id.
    ///
    /// The client's reconcile path: on (re)connect, foreground, a detected
    /// version gap, or manual refresh, the host fetches the current descriptor
    /// and folds it through the same version-gated upsert as a push, so a pull
    /// that races a newer push converges. Pull is authoritative; push is a
    /// best-effort hint, so a missed or out-of-order push self-heals here.
    ///
    /// Not part of ``CmuxAgentChat/ChatEventSource`` (which is scoped to one
    /// conversation). Throws when the host no longer knows the session (treat
    /// as gone) or the request fails.
    ///
    /// - Parameter sessionID: The session to snapshot.
    /// - Returns: The session's current descriptor, with its `version`.
    public func session(sessionID: String) async throws -> ChatSessionDescriptor {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.session",
            params: ["session_id": sessionID]
        )
        let result = try await client.sendRequest(request)
        return try coding.decode(MobileChatSessionResponse.self, from: result).session
    }

    /// Opens the live stream of session-list events for every session the
    /// Mac knows about (not scoped to one conversation).
    ///
    /// Yields each `chat.message` frame whole, so a host can fold
    /// `descriptorChanged`/`stateChanged` into its session list (and keep
    /// the GUI toggle current) without polling. A newly-started agent emits
    /// `descriptorChanged`, so the list gains it live. The stream finishes
    /// when the connection drops; callers re-subscribe after reconnect.
    ///
    /// - Returns: Live session frames, in delivery order.
    public func sessionEvents() async -> AsyncStream<ChatSessionEventFrame> {
        let envelopes = await client.subscribe(to: ["chat.message"])
        let client = self.client
        let coding = self.coding
        let streamID = UUID().uuidString
        return AsyncStream { continuation in
            let pump = Task {
                // Register after the local listener exists so no frame falls
                // between subscribe and handshake; a failed handshake must
                // finish the stream (the server never feeds an unregistered
                // connection).
                do {
                    let subscribe = try MobileCoreRPCClient.requestData(
                        method: "mobile.events.subscribe",
                        params: [
                            "topics": ["chat.message"],
                            "stream_id": streamID,
                        ]
                    )
                    _ = try await client.sendRequest(subscribe)
                } catch {
                    continuation.finish()
                    return
                }
                for await envelope in envelopes {
                    guard let payload = envelope.payloadJSON else { continue }
                    guard let frame = try? coding.decode(ChatSessionEventFrame.self, from: payload) else {
                        continue
                    }
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                pump.cancel()
                // Withdraw the registration only on consumer cancellation; a
                // `.finished` means the connection died and an unsubscribe
                // would reopen a torn-down transport (see `events`).
                guard case .cancelled = reason else { return }
                Task {
                    if let unsubscribe = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) {
                        _ = try? await client.sendRequest(unsubscribe)
                    }
                }
            }
        }
    }

    public func history(sessionID: String, beforeSeq: Int?, limit: Int) async throws -> ChatHistoryPage {
        var params: [String: Any] = [
            "session_id": sessionID,
            "limit": limit,
        ]
        if let beforeSeq {
            params["before_seq"] = beforeSeq
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.history", params: params)
        let result = try await client.sendRequest(request)
        return try coding.decode(ChatHistoryPage.self, from: result)
    }

    public func events(sessionID: String) async -> AsyncStream<ChatSessionEvent> {
        let envelopes = await client.subscribe(to: ["chat.message"])
        let client = self.client
        let coding = self.coding
        let streamID = UUID().uuidString
        return AsyncStream { continuation in
            let pump = Task {
                // Server-side handshake after the local listener exists so no
                // early event falls between the two. A failed handshake must
                // finish the stream: the server never feeds an unregistered
                // connection, so continuing would wedge the consumer in a
                // silent "connected but deaf" state.
                do {
                    let subscribe = try MobileCoreRPCClient.requestData(
                        method: "mobile.events.subscribe",
                        params: [
                            "topics": ["chat.message"],
                            "stream_id": streamID,
                        ]
                    )
                    _ = try await client.sendRequest(subscribe)
                } catch {
                    continuation.finish()
                    return
                }
                for await envelope in envelopes {
                    guard let payload = envelope.payloadJSON else { continue }
                    guard let frame = try? coding.decode(ChatSessionEventFrame.self, from: payload) else {
                        continue
                    }
                    guard frame.sessionID == sessionID else { continue }
                    continuation.yield(frame.event)
                }
                continuation.finish()
            }
            continuation.onTermination = { reason in
                pump.cancel()
                // Withdraw the server-side registration only when the
                // CONSUMER cancelled a live stream (chat closed). A
                // `.finished` termination means the connection itself died
                // (or the handshake failed); sending an unsubscribe there
                // would reopen a torn-down transport just to clean up a
                // registration that died with it.
                guard case .cancelled = reason else { return }
                Task {
                    if let unsubscribe = try? MobileCoreRPCClient.requestData(
                        method: "mobile.events.unsubscribe",
                        params: ["stream_id": streamID]
                    ) {
                        _ = try? await client.sendRequest(unsubscribe)
                    }
                }
            }
        }
    }

    public func send(text: String, attachments: [ChatOutboundAttachment], sessionID: String) async throws {
        var params: [String: Any] = [
            "session_id": sessionID,
            "text": text,
        ]
        if !attachments.isEmpty {
            params["attachments"] = attachments.map { attachment in
                [
                    "data_b64": attachment.data.base64EncodedString(),
                    "format": attachment.format.rawValue,
                ]
            }
        }
        let request = try MobileCoreRPCClient.requestData(method: "mobile.chat.send", params: params)
        _ = try await client.sendRequest(request)
    }

    public func interrupt(sessionID: String, hard: Bool) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.interrupt",
            params: [
                "session_id": sessionID,
                "hard": hard,
            ]
        )
        _ = try await client.sendRequest(request)
    }

    public func answer(optionIndex: Int, sessionID: String) async throws {
        let request = try MobileCoreRPCClient.requestData(
            method: "mobile.chat.answer",
            params: [
                "session_id": sessionID,
                "option_index": optionIndex,
            ]
        )
        _ = try await client.sendRequest(request)
    }
}
