public import CmuxSyncStore
public import Foundation

/// A ``SyncTransport`` over a dedicated authenticated presence WebSocket.
///
/// The cmux-presence Durable Object serves the `sync/v1` snapshot/delta protocol
/// on the same `/v1/presence/subscribe` socket as presence. This transport opens
/// its OWN socket to that endpoint (so the live presence stream and its
/// online-dot / route-push path are never disturbed), sends the `sync.hello`,
/// and yields raw inbound frames to ``SyncClient``. ``SyncClient`` ignores the
/// presence snapshot/tick noise on this socket (non-sync JSON parses to
/// `.unknown` and commits nothing), so the two protocols coexist; consolidating
/// onto the one presence socket is a later optimization, not required for
/// correctness.
///
/// One instance per subscription attempt: the socket opens lazily on first use
/// and closes when the frame stream terminates. Auth mirrors ``PresenceClient``
/// (Bearer access token + optional `X-Cmux-Team-Id`), pinned to one team id so
/// the stored records and the socket scope agree.
public actor PresenceSyncTransport: SyncTransport {
    private let serviceBaseURL: String
    private let tokenSource: PresenceTokenSource
    private let teamID: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    /// Create a sync transport.
    /// - Parameters:
    ///   - serviceBaseURL: Presence service origin (no trailing slash), e.g. the
    ///     deployed cmux-presence worker URL.
    ///   - tokenSource: Supplies the Stack access token for the WebSocket auth.
    ///   - teamID: Team to pin the socket (and the stored records) to.
    ///   - session: URL session used for the WebSocket transport.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        teamID: String,
        session: sending URLSession = .shared
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.teamID = teamID
        self.session = session
    }

    /// Send one text frame (the `sync.hello`), opening the WebSocket lazily on
    /// first use. Throws on auth/transport failure so the caller can reconnect.
    public func send(_ data: Data) async throws {
        let task = try await connectedTask()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    /// The inbound raw-frame stream. Opens the WebSocket lazily and yields each
    /// message verbatim (the client parses it); the stream ends when the socket
    /// closes, on a dropped frame, or on transport error.
    public nonisolated func frames() -> AsyncThrowingStream<Data, any Error> {
        // Bounded buffer (the shared socket also carries the team's frequent
        // presence ticks, so unbounded could grow if the consumer stalls), but
        // `bufferingOldest`, NOT `bufferingNewest`. The sync protocol is
        // cursor-based: `applyDelta` advances the cursor to a frame's rev with no
        // contiguity guard, so a dropped frame in the MIDDLE silently loses a rev
        // (the cursor steps over it). `bufferingNewest` would drop the oldest and
        // deliver a non-contiguous tail — exactly that bug. `bufferingOldest`
        // instead drops the NEWEST frames on overflow, so what is delivered stays
        // a contiguous prefix and the cursor never advances past a gap; the
        // dropped recent frames are simply re-sent from the persisted cursor when
        // we reconnect and re-`hello`. On any drop we still end the stream so that
        // reconnect happens promptly rather than waiting out the stall.
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let pump = Task {
                do {
                    let task = try await self.connectedTask()
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        let frame: Data
                        switch message {
                        case .string(let text): frame = Data(text.utf8)
                        case .data(let raw): frame = raw
                        @unknown default: continue
                        }
                        switch continuation.yield(frame) {
                        case .enqueued:
                            break
                        case .dropped:
                            // A newest frame was dropped (buffer full). The
                            // delivered prefix is still contiguous, so the cursor
                            // is safe; end the stream so SyncClient reconnects and
                            // re-hellos from that cursor to catch up the dropped
                            // tail.
                            continuation.finish(throwing: PresenceClientError.updatesDropped)
                            return
                        case .terminated:
                            return
                        @unknown default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                Task { await self.close() }
            }
        }
    }

    private func connectedTask() async throws -> URLSessionWebSocketTask {
        if let task { return task }
        guard let url = PresenceClient.subscribeURL(serviceBaseURL: serviceBaseURL) else {
            throw PresenceClientError.invalidServiceURL
        }
        guard let accessToken = await tokenSource.accessToken() else {
            throw PresenceClientError.notAuthenticated
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        self.task = task
        return task
    }

    private func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
