import Foundation

/// Endpoint resolution for the share service. The base URL can be pointed at
/// a local `wrangler dev` instance with
/// `defaults write <bundle> cmux.share.serviceURL http://127.0.0.1:8787`.
enum WorkspaceShareEndpoints {
    static let serviceURLDefaultsKey = "cmux.share.serviceURL"
    static let defaultServiceURL = URL(string: "https://share.cmux.dev")!
    /// The user-facing share page origin (the worker URL is transport-only).
    static let sharePageBase = URL(string: "https://cmux.com/share/")!

    static func serviceBaseURL(defaults: UserDefaults = .standard) -> URL {
        if let raw = defaults.string(forKey: serviceURLDefaultsKey),
           let url = URL(string: raw), url.scheme != nil {
            return url
        }
        return defaultServiceURL
    }

    static func createURL(base: URL) -> URL {
        base.appendingPathComponent("v1/share/create")
    }

    static func hostSocketURL(base: URL, shareId: String, hostToken: String) -> URL? {
        guard var components = URLComponents(
            url: base.appendingPathComponent("v1/share/\(shareId)/host"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.queryItems = [URLQueryItem(name: "token", value: hostToken)]
        return components.url
    }

    static func sharePageURL(shareId: String) -> URL {
        sharePageBase.appendingPathComponent(shareId)
    }
}

/// One WebSocket connection attempt to the ShareSession Durable Object host
/// lane. Owns a `URLSessionWebSocketTask`; outbound frames are serialized
/// through a single sender task so per-surface `term` ordering is preserved.
/// Reconnect policy lives in `WorkspaceShareService`; this type is one
/// connection, dead once it fails.
@MainActor
final class WorkspaceShareSocket {
    enum SocketError: Error {
        case sendFailed
        case receiveFailed
    }

    private let task: URLSessionWebSocketTask
    private var outboundContinuation: AsyncStream<Data>.Continuation?
    private var senderTask: Task<Void, Never>?
    private(set) var isClosed = false

    init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
    }

    /// Connects and starts the sender loop. Frames yielded before the socket
    /// finishes its handshake are buffered by URLSession.
    func start() {
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        outboundContinuation = continuation
        task.resume()
        let webSocketTask = task
        senderTask = Task { [weak self] in
            for await data in stream {
                guard let text = String(data: data, encoding: .utf8) else { continue }
                do {
                    try await webSocketTask.send(.string(text))
                } catch {
                    await self?.markClosed()
                    break
                }
            }
        }
    }

    func send(_ frame: ShareOutboundFrame) {
        guard !isClosed, let data = try? frame.encodedJSONData() else { return }
        outboundContinuation?.yield(data)
    }

    /// Receives one inbound frame; throws when the socket is dead.
    func receive() async throws -> ShareInboundFrame {
        let message = try await task.receive()
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let raw):
            data = raw
        @unknown default:
            return .unknown(type: "")
        }
        return try ShareInboundFrame.decode(fromJSONData: data)
    }

    func close(sendEnd: Bool) {
        guard !isClosed else { return }
        if sendEnd, let data = try? ShareOutboundFrame.end.encodedJSONData() {
            outboundContinuation?.yield(data)
        }
        isClosed = true
        outboundContinuation?.finish()
        outboundContinuation = nil
        // Give the sender loop a chance to flush the `end` frame; the task
        // cancel below tears down the connection either way.
        senderTask = nil
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func markClosed() {
        isClosed = true
        outboundContinuation?.finish()
        outboundContinuation = nil
    }
}
