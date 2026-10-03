import Foundation

/// A text WebSocket as the signaling client needs it. `URLSessionSignalingTransport` is the real
/// one; tests inject an in-memory pair.
public protocol RTCSignalingSocket: Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func ping() async throws
    func close()
    /// The close code once the socket has closed, else nil.
    var closeCode: Int? { get }
}

public protocol RTCSignalingTransport: Sendable {
    func open(url: URL, protocols: [String]) async throws -> any RTCSignalingSocket
}

/// What the signaling client reports, in order, on `SignalingClient.events`.
public enum RTCSignalingEvent: Sendable, Equatable {
    /// The socket is open and `rtc.hello` was accepted.
    case online
    /// The socket dropped; the client reconnects on its own.
    case offline(reason: String)
    case hosts([RTCHostInfo])
    case signal(RTCSignalMessage)
    case error(code: String, session: String?, peer: String?)
}

public enum RTCSignalingError: Error, Equatable {
    case offline
}

/// The device's signaling presence: one socket to `/v1/wire/user`, re-opened with capped
/// exponential backoff (never above 30 s) until `stop()`. Every reconnect says hello again, so the
/// backend lists a host exactly while it is reachable.
public actor SignalingClient {
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    public nonisolated let events: AsyncStream<RTCSignalingEvent>
    private let continuation: AsyncStream<RTCSignalingEvent>.Continuation
    private let baseURL: URL
    private let hello: RTCHello
    private let token: TokenProvider
    private let transport: any RTCSignalingTransport
    private let clock: any Clock<Duration>
    private let pingInterval: Duration
    private var socket: (any RTCSignalingSocket)?
    private var loop: Task<Void, Never>?

    public init(
        baseURL: URL,
        hello: RTCHello,
        token: @escaping TokenProvider,
        transport: any RTCSignalingTransport = URLSessionSignalingTransport(),
        clock: any Clock<Duration> = ContinuousClock(),
        pingInterval: Duration = .seconds(20)
    ) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.baseURL = baseURL
        self.hello = hello
        self.token = token
        self.transport = transport
        self.clock = clock
        self.pingInterval = pingInterval
    }

    public var isOnline: Bool { socket != nil }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        socket?.close()
        socket = nil
        continuation.finish()
    }

    /// Sends one signaling message; throws `.offline` while the socket is down (the caller's
    /// session restarts negotiation when the socket returns).
    public func send(_ message: RTCSignalMessage) async throws {
        guard let socket else { throw RTCSignalingError.offline }
        try await socket.send(message.encodedFrame)
    }

    public func refreshHosts() async {
        try? await socket?.send(RTCServerFrame.hostsRequestFrame)
    }

    private var wireURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/v1/wire/user"
        return components.url ?? baseURL
    }

    private func run() async {
        var attempt = 0
        var forceRefresh = false
        while !Task.isCancelled {
            var reason = "closed"
            do {
                let bearer = try await token(forceRefresh)
                forceRefresh = false
                let socket = try await transport.open(url: wireURL, protocols: ["cmux.wire.v1", "bearer.\(bearer)"])
                self.socket = socket
                try await socket.send(hello.encodedFrame)
                reason = try await receive(on: socket, onWelcome: { attempt = 0 })
            } catch is CancellationError {
                break
            } catch {
                reason = String(describing: error)
            }
            let code = socket?.closeCode
            socket?.close()
            socket = nil
            // 4401: the token expired; the next attempt mints a fresh one.
            if code == 4401 { forceRefresh = true }
            if Task.isCancelled { break }
            continuation.yield(.offline(reason: reason))
            attempt += 1
            let seconds = min(30.0, 0.5 * pow(2.0, Double(min(attempt, 8))))
            do {
                try await clock.sleep(for: .milliseconds(Int(seconds * 1000)))
            } catch {
                break
            }
        }
    }

    private func receive(on socket: any RTCSignalingSocket, onWelcome: () -> Void) async throws -> String {
        let pinger = Task { [clock, pingInterval] in
            while !Task.isCancelled {
                try await clock.sleep(for: pingInterval)
                try await socket.ping()
            }
        }
        defer { pinger.cancel() }
        while true {
            let text = try await socket.receive()
            guard let frame = RTCServerFrame(decoding: text) else { continue }
            switch frame {
            case .welcome:
                onWelcome()
                continuation.yield(.online)
            case let .hosts(hosts):
                continuation.yield(.hosts(hosts))
            case let .signal(message):
                continuation.yield(.signal(message))
            case let .error(code, session, peer):
                continuation.yield(.error(code: code, session: session, peer: peer))
            }
        }
    }
}

/// `URLSessionWebSocketTask` transport.
public struct URLSessionSignalingTransport: RTCSignalingTransport {
    public init() {}

    public func open(url: URL, protocols: [String]) async throws -> any RTCSignalingSocket {
        let task = URLSession.shared.webSocketTask(with: url, protocols: protocols)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionSignalingSocket(task: task)
    }
}

final class URLSessionSignalingSocket: RTCSignalingSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    var closeCode: Int? { task.closeCode == .invalid ? nil : task.closeCode.rawValue }
}
