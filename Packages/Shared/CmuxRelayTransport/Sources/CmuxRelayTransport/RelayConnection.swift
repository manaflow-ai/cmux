// One WebSocket to a HostRelay Durable Object. Both roles use this: the host
// keeps one for all phone sessions, a client keeps one to its current host.
//
// `RelayConnecting` exists so RelayHostLink and RelayClientByteTransport can
// be unit-tested against a scripted fake; RelayConnection is the URLSession
// implementation.

import Foundation

public enum RelayConnectionEvent: Sendable {
    case control(RelayServerMessage)
    case data(RelayDataFrame)
}

public enum RelayConnectionError: Error, Sendable {
    case notConnected
    case handshakeFailed(String)
    case protocolViolation(String)
    case sendFailed(String)
}

public protocol RelayConnecting: Sendable {
    /// Opens the socket and returns the relay's `welcome`.
    func connect() async throws -> RelayWelcome
    /// The single-consumer event stream. Finishes when the socket closes.
    func events() async -> AsyncStream<RelayConnectionEvent>
    func sendData(sessionID: UInt32, payload: Data) async throws
    func sendControl(_ json: Data) async throws
    func close() async
}

/// Builds connections; injected so tests can script them.
public typealias RelayConnectionFactory = @Sendable (_ url: URL, _ ticket: String) -> any RelayConnecting

public actor RelayConnection: RelayConnecting {
    private let url: URL
    private let ticket: String
    private let urlSession: URLSession
    private var task: URLSessionWebSocketTask?
    private var pumpTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var eventStream: AsyncStream<RelayConnectionEvent>?
    private var eventContinuation: AsyncStream<RelayConnectionEvent>.Continuation?

    public init(url: URL, ticket: String, urlSession: URLSession = .shared) {
        self.url = url
        self.ticket = ticket
        self.urlSession = urlSession
    }

    public static func factory(urlSession: URLSession = .shared) -> RelayConnectionFactory {
        { url, ticket in RelayConnection(url: url, ticket: ticket, urlSession: urlSession) }
    }

    public func connect() async throws -> RelayWelcome {
        var request = URLRequest(url: url)
        request.setValue(ticket, forHTTPHeaderField: RelayProtocol.ticketHeaderName)
        request.timeoutInterval = 15
        let task = urlSession.webSocketTask(with: request)
        task.maximumMessageSize = RelayProtocol.dataHeaderBytes + RelayProtocol.maxDataPayloadBytes
        self.task = task
        task.resume()

        // The first frame must be the welcome; anything else is a protocol
        // violation from a same-version relay.
        let first = try await receiveMessage(task)
        guard case .string(let text) = first,
              let message = RelayServerMessage.decode(Data(text.utf8)),
              case .welcome(let welcome) = message else {
            await close()
            throw RelayConnectionError.handshakeFailed("expected welcome frame")
        }

        let (stream, continuation) = AsyncStream.makeStream(of: RelayConnectionEvent.self)
        eventStream = stream
        eventContinuation = continuation
        pumpTask = Task { [weak self] in
            await self?.pump(task)
        }
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                await self?.sendKeepalive()
            }
        }
        return welcome
    }

    public func events() async -> AsyncStream<RelayConnectionEvent> {
        eventStream ?? AsyncStream { $0.finish() }
    }

    public func sendData(sessionID: UInt32, payload: Data) async throws {
        guard let task else { throw RelayConnectionError.notConnected }
        let frame = RelayFrameCodec.encodeDataFrame(sessionID: sessionID, payload: payload)
        do {
            try await task.send(.data(frame))
        } catch {
            throw RelayConnectionError.sendFailed(String(describing: error))
        }
    }

    public func sendControl(_ json: Data) async throws {
        guard let task else { throw RelayConnectionError.notConnected }
        guard let text = String(data: json, encoding: .utf8) else {
            throw RelayConnectionError.sendFailed("control frame is not UTF-8")
        }
        do {
            try await task.send(.string(text))
        } catch {
            throw RelayConnectionError.sendFailed(String(describing: error))
        }
    }

    public func close() async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        pumpTask?.cancel()
        pumpTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        eventContinuation?.finish()
        eventContinuation = nil
    }

    private func sendKeepalive() async {
        guard let task else { return }
        try? await task.send(.string(RelayProtocol.pingText))
    }

    private func receiveMessage(
        _ task: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    private func pump(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                break
            }
            switch message {
            case .string(let text):
                if text == RelayProtocol.pongText { continue }
                guard let decoded = RelayServerMessage.decode(Data(text.utf8)) else { continue }
                eventContinuation?.yield(.control(decoded))
            case .data(let data):
                guard let frame = RelayFrameCodec.decodeDataFrame(data) else { continue }
                eventContinuation?.yield(.data(frame))
            @unknown default:
                continue
            }
        }
        eventContinuation?.finish()
        eventContinuation = nil
    }
}
