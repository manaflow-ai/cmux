import Foundation

/// One GPT-Live WebSocket session: connect, stream server events, send client
/// events, close. Modeled on `V2URLSessionSocket` (URLSessionWebSocketTask on
/// an actor) but scoped to the Live protocol.
///
/// Lifecycle: `events()` opens the socket and returns the server-event
/// stream; the stream finishing means the session is over (gracefully via
/// `session.closed` or through transport loss, surfaced as
/// ``VoiceLiveServerEvent/closed(reason:)`` with `connection_lost`).
public actor VoiceLiveSessionClient {
    private let request: URLRequest
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var eventCounter = 0
    private var finished = false

    /// - Parameters:
    ///   - endpoint: The Live sessions WebSocket URL.
    ///   - bearerToken: The OpenAI credential for the `Authorization` header
    ///     (from the server-minted grant or the user's own key).
    public init(
        endpoint: URL,
        bearerToken: String,
        urlSession: URLSession = URLSession(configuration: .ephemeral)
    ) {
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        self.request = request
        self.urlSession = urlSession
    }

    /// Open the socket and return the server-event stream. Call once.
    public func events() -> AsyncStream<VoiceLiveServerEvent> {
        let task = urlSession.webSocketTask(with: request)
        // Speech audio deltas are small; 4 MB leaves generous headroom.
        task.maximumMessageSize = 4 * 1_024 * 1_024
        self.task = task
        task.resume()
        return AsyncStream { continuation in
            let pump = Task {
                while !Task.isCancelled {
                    do {
                        let message = try await task.receive()
                        let data: Data
                        switch message {
                        case .data(let raw):
                            data = raw
                        case .string(let text):
                            data = Data(text.utf8)
                        @unknown default:
                            continue
                        }
                        guard let event = VoiceLiveServerEvent.parse(data) else { continue }
                        continuation.yield(event)
                        if case .closed = event {
                            break
                        }
                    } catch {
                        // Transport failure or cancellation: report as a
                        // close so the controller has one teardown path.
                        continuation.yield(.closed(reason: "connection_lost"))
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                pump.cancel()
            }
        }
    }

    /// Send one client event. Throws when the socket is gone; the caller
    /// treats that the same as a `closed` event.
    public func send(_ event: VoiceLiveClientEvent) async throws {
        guard let task, !finished else {
            throw VoiceLiveSessionClientError.notConnected
        }
        eventCounter += 1
        let data = try event.jsonData(eventID: "evt_\(eventCounter)")
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceLiveSessionClientError.encodingFailed
        }
        try await task.send(.string(text))
    }

    /// Request a graceful close. The receive loop keeps draining so the final
    /// `session.closed` (with usage) still reaches the event stream; the
    /// socket itself is torn down in ``shutdown()``.
    public func requestClose() async {
        try? await send(.sessionClose)
    }

    /// Tear the transport down. Idempotent.
    public func shutdown() {
        guard !finished else { return }
        finished = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

public enum VoiceLiveSessionClientError: Error {
    case notConnected
    case encodingFailed
}
