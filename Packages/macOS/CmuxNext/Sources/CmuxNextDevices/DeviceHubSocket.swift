public import CmuxNextWakeups
public import Foundation

/// One open text WebSocket.
public protocol DeviceHubSocketConnection: Sendable {
    /// The next text frame; throws when the socket closes.
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close()
}

/// Opens the User DO socket (a fresh, newly signed upgrade request each time).
public protocol DeviceHubSocketConnector: Sendable {
    func connect() async throws -> any DeviceHubSocketConnection
}

/// The User DO socket over URLSession, its upgrade request from the client.
public struct URLSessionDeviceHubConnector: DeviceHubSocketConnector {
    public let client: DeviceHubClient
    let session: URLSession

    public init(client: DeviceHubClient, session: URLSession = DeviceHubClient.transport) {
        self.client = client
        self.session = session
    }

    public func connect() async throws -> any DeviceHubSocketConnection {
        let handshake = try await client.userSocketHandshake()
        let task = session.webSocketTask(with: handshake.request)
        task.maximumMessageSize = 1 << 20
        task.resume()
        return URLSessionSocketConnection(task: task)
    }
}

/// A URLSessionWebSocketTask as a ``DeviceHubSocketConnection``.
public struct URLSessionSocketConnection: DeviceHubSocketConnection {
    let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    public func receive() async throws -> String {
        let message: URLSessionWebSocketTask.Message
        do { message = try await task.receive() } catch {
            // The server's close code, when it closed the socket (4000 replaced, 4001 removed, 4003 signed out).
            if task.closeCode != .invalid { throw DeviceHubSocket.Closed(code: task.closeCode.rawValue) }
            throw error
        }
        switch message {
        case let .string(text): return text
        case let .data(data): return String(decoding: data, as: UTF8.self)
        @unknown default: return ""
        }
    }

    public func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// The device's socket to its User DO: pushes in, `{type:'ping'}` out on an
/// interval, and a reconnect with jittered backoff whenever it drops. While
/// a socket is open nothing else wakes it but frames and the ping.
public final class DeviceHubSocket: Sendable {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        /// The last attempt failed; the next one follows the backoff.
        case reconnecting(String)
        /// Another connection of this device took over (close code 4000): no reconnect.
        case replaced
        /// The hub removed this device (close code 4001): no reconnect.
        case removed
        /// This device signed out of the hub (close code 4003): no reconnect.
        case signedOut
    }

    /// The server closed the socket with `code`.
    public struct Closed: Error, Equatable, Sendable {
        public var code: Int
        public init(code: Int) { self.code = code }
    }

    public enum Event: Sendable, Equatable {
        case state(State)
        case push(DeviceHubPush)
    }

    let connector: any DeviceHubSocketConnector
    let pingInterval: Duration
    let backoff: Backoff
    let clock: any Clock<Duration>

    public init(connector: any DeviceHubSocketConnector, pingInterval: Duration = .seconds(30),
                backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(60)), clock: any Clock<Duration> = ContinuousClock()) {
        self.connector = connector
        self.pingInterval = pingInterval
        self.backoff = backoff
        self.clock = clock
    }

    /// Connects and keeps connecting until the calling task is cancelled.
    /// `handler` gets every state change and push, in order.
    public func run(_ handler: @escaping @Sendable (Event) async -> Void) async {
        var backoff = self.backoff
        // wakeup-allow: the reconnect loop; each pass waits on a connect, the socket's frames, or Backoff after a failure.
        while !Task.isCancelled {
            await handler(.state(.connecting))
            var failure = "the socket closed"
            var closeCode: Int?
            do {
                let connection = try await connector.connect()
                await handler(.state(.connected))
                backoff.reset()
                do { try await serve(connection, handler) } catch {
                    failure = "\(error)"
                    closeCode = (error as? Closed)?.code
                }
                connection.close()
            } catch {
                failure = "\(error)"
            }
            if Task.isCancelled { break }
            if let terminal = closeCode.flatMap(Self.terminalState(closeCode:)) {
                await handler(.state(terminal))
                return
            }
            await handler(.state(.reconnecting(failure)))
            // concurrency-allow: Backoff.wait is an async sleep on the injected clock, not a blocking wait.
            do { try await backoff.wait(owner: "device-hub.socket", clock: clock) } catch { break }
        }
        await handler(.state(.disconnected))
    }

    /// The state a server close code ends the socket in, with no reconnect (PROTOCOL.md,
    /// WebSocket: User DO); nil for a close the socket reconnects after.
    static func terminalState(closeCode: Int) -> State? {
        switch closeCode {
        case 4000: .replaced
        case 4001: .removed
        case 4003: .signedOut
        default: nil
        }
    }

    /// Reads frames and pings until the socket fails or the task is cancelled.
    private func serve(_ connection: any DeviceHubSocketConnection, _ handler: @escaping @Sendable (Event) async -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.ping(connection) }
                group.addTask { try await Self.read(connection, handler) }
                // The first to end (a failed read or ping) ends both: closing the socket ends the read.
                defer {
                    group.cancelAll()
                    connection.close()
                }
                _ = try await group.next()
            }
        } onCancel: {
            // receive() does not end on cancellation by itself; closing the socket ends it.
            connection.close()
        }
    }

    private static func read(_ connection: any DeviceHubSocketConnection, _ handler: @escaping @Sendable (Event) async -> Void) async throws {
        // wakeup-allow: each pass waits for the next frame; it ends when the socket throws.
        while !Task.isCancelled {
            let text = try await connection.receive()
            if let push = DeviceHubPush(text: text) { await handler(.push(push)) }
        }
    }

    private func ping(_ connection: any DeviceHubSocketConnection) async throws {
        // wakeup-allow: PROTOCOL.md's keepalive; the server answers without waking its object.
        while !Task.isCancelled {
            // poll-allow: a keepalive is due every interval by protocol; it waits for no condition, so no event exists.
            try await clock.sleep(for: pingInterval) // wakeup-allow: the ping interval (PROTOCOL.md keepalive)
            try await connection.send(#"{"type":"ping"}"#)
        }
    }
}
