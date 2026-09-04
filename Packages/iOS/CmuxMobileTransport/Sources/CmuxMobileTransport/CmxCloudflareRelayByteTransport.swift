public import CMUXMobileCore
public import Foundation

/// Errors raised while establishing or operating a
/// ``CmxCloudflareRelayByteTransport``.
public enum CmxCloudflareRelayByteTransportError: Error, Equatable, Sendable {
    /// The connection failed or was never opened; the associated value
    /// describes the underlying `URLSessionWebSocketTask` failure.
    case connectionFailed(String)
    /// A send was attempted before `connect()` succeeded, or after `close()`.
    case notConnected
    /// The transport was already closed.
    case alreadyClosed
}

/// A ``CmxByteTransport`` over a Cloudflare Durable Objects WebSocket relay
/// (`workers/presence`'s `MobilePairingRelay` Durable Object).
///
/// Every `send`/`receive` carries a raw chunk of the same length-prefixed
/// `MobileSyncFrameCodec` byte stream ``CmxNetworkByteTransport`` carries over
/// TCP — the relay Durable Object never parses cmux content, it only pipes
/// binary WebSocket messages between the Mac's `/host` leg and the paired
/// device's `/client` leg, so the RPC layer above this transport (which
/// already re-synchronizes frames from arbitrarily-chunked bytes) needs no
/// changes to use it.
///
/// `connect()` waits for a WebSocket pong before returning, so a caller that
/// awaits it before publishing a route (see
/// `MobileHostCloudflareRelayRuntime`) never advertises a route the relay
/// hasn't actually accepted yet — unlike a plain `.resume()`, which only
/// starts the handshake.
public actor CmxCloudflareRelayByteTransport: CmxByteTransport {
    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var isClosed = false

    /// - Parameters:
    ///   - url: The `wss://.../v1/mobile-relay/<macDeviceID>/host` URL.
    ///   - bearerToken: Stack access token, sent as `Authorization: Bearer
    ///     <token>` on the upgrade request — the Worker requires it to open
    ///     the socket at all.
    public init(url: URL, bearerToken: String, session: URLSession = .shared) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        self.request = request
        self.session = session
    }

    public func connect() async throws {
        guard !isClosed else {
            throw CmxCloudflareRelayByteTransportError.alreadyClosed
        }
        guard task == nil else {
            return
        }
        let newTask = session.webSocketTask(with: request)
        task = newTask
        newTask.resume()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            newTask.sendPing { error in
                if let error {
                    continuation.resume(
                        throwing: CmxCloudflareRelayByteTransportError.connectionFailed(
                            String(describing: error)
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    public func receive() async throws -> Data? {
        guard let task, !isClosed else {
            return nil
        }
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if isClosed {
                    return nil
                }
                throw CmxCloudflareRelayByteTransportError.connectionFailed(String(describing: error))
            }
            switch message {
            case let .data(data):
                return data
            case .string:
                // Transport-liveness heartbeats only (the relay DO's ping/pong
                // convention); every cmux payload frame is binary.
                continue
            @unknown default:
                continue
            }
        }
    }

    public func send(_ data: Data) async throws {
        guard !data.isEmpty else {
            return
        }
        guard let task, !isClosed else {
            throw CmxCloudflareRelayByteTransportError.notConnected
        }
        do {
            try await task.send(.data(data))
        } catch {
            throw CmxCloudflareRelayByteTransportError.connectionFailed(String(describing: error))
        }
    }

    public func close() async {
        guard !isClosed else {
            return
        }
        isClosed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
