import Foundation

/// One signaling message, relayed by the room between host and viewer.
struct SignalMessage: Codable, Sendable {
    var type: String
    var sdp: String?
    var candidate: String?
    var sdpMid: String?
    var sdpMLineIndex: Int32?
    var role: String?
    var peer: Bool?
}

/// The room's WebSocket for one role.
// crash-allow: its only stored state is a `let` URLSessionWebSocketTask, which is thread-safe.
final class SignalSocket: @unchecked Sendable {
    // @unchecked: URLSessionWebSocketTask is thread-safe; nothing else is mutable.
    private let task: URLSessionWebSocketTask

    /// Requests carry the room secret (a header) and the answers TURN
    /// credentials: no disk cache, no cookies, nothing kept after the process.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    init(pairing: VNCPairing, role: String) {
        var request = URLRequest(url: pairing.url("ws", query: [URLQueryItem(name: "role", value: role)]))
        request.setValue(pairing.secret, forHTTPHeaderField: "x-room-secret")
        task = Self.session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
    }

    /// Messages until the socket closes.
    func messages() -> AsyncThrowingStream<SignalMessage, any Error> {
        task.resume()
        let task = self.task
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard case let .string(text) = message,
                              let decoded = try? JSONDecoder().decode(SignalMessage.self, from: Data(text.utf8)) else { continue }
                        continuation.yield(decoded)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Keepalive: an idle WebSocket can be dropped by a NAT or proxy
            // without either end hearing about it; a failed ping surfaces it.
            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(20)) // keepalive period
                    task.sendPing { error in if error != nil { task.cancel(with: .goingAway, reason: nil) } }
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                pinger.cancel()
            }
        }
    }

    func send(_ message: SignalMessage) async throws {
        let data = try JSONEncoder().encode(message)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    /// The room's ICE servers (STUN, plus TURN when the Worker has a key).
    static func iceServers(_ pairing: VNCPairing) async throws -> [ICEServerConfig] {
        var request = URLRequest(url: pairing.url("ice"))
        request.setValue(pairing.secret, forHTTPHeaderField: "x-room-secret")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw VNCWebRTCError.signaling("ICE servers: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return try JSONDecoder().decode(ICEAnswer.self, from: data).iceServers
    }
}

/// One ICE server (STUN or TURN), as WebRTC configures it.
public struct ICEServerConfig: Codable, Sendable, Equatable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

private struct ICEAnswer: Codable {
    var iceServers: [ICEServerConfig]
}

public enum VNCWebRTCError: Error, Sendable, CustomStringConvertible {
    case signaling(String)
    case peer(String)
    case closed

    public var description: String {
        switch self {
        case let .signaling(detail): "signaling: \(detail)"
        case let .peer(detail): "WebRTC: \(detail)"
        case .closed: "the WebRTC connection closed"
        }
    }
}
