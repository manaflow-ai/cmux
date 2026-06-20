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

    public func send(_ data: Data) async throws {
        let task = try await connectedTask()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, any Error> {
        // Bounded buffer like PresenceClient: the shared socket also carries the
        // team's frequent presence ticks, so an unbounded policy would grow if
        // the consumer stalls.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
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
                            // The sync protocol is stateful (snapshot + deltas);
                            // continuing past a dropped frame could let the cursor
                            // advance over a gap. End the stream so SyncClient
                            // resets and re-hellos for a fresh snapshot.
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
