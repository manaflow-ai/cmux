import CmuxEgress
public import CmuxNextWakeups
public import Foundation
import os

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
        let task = CmuxEgress.websocket(session, with: handshake.request, site: "CmuxNextDevices.DeviceHubSocket")
        task.maximumMessageSize = 1 << 20
        task.resume()
        // Connected means upgraded: the first pong comes only once the hub accepted the socket. A
        // refused upgrade (a stale signature, a 401) throws here with its status, so it is a
        // failed connect that backs off and says why, not a "connected" that drops at once.
        do { try await Self.firstPong(task) } catch {
            let status = (task.response as? HTTPURLResponse)?.statusCode
            task.cancel(with: .goingAway, reason: nil)
            if let status, status != 101 { throw DeviceHubError.http(status: status) }
            throw error
        }
        return URLSessionSocketConnection(task: task)
    }

    private static func firstPong(_ task: URLSessionWebSocketTask) async throws {
        // URLSession may call a ping's handler twice during teardown: the continuation resumes once.
        // lint:allow lock -- the URLSession callback is synchronous; it claims the one resume without an async hop.
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                task.sendPing { error in
                    guard resumed.withLock({ let first = !$0; $0 = true; return first }) else { return }
                    if let error { done.resume(throwing: error) } else { done.resume() }
                }
            }
        } onCancel: {
            // Cancelling the task fails the ping, which resumes the wait.
            task.cancel(with: .goingAway, reason: nil)
        }
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
    /// A WebSocket upgrade or its first ping can stay pending when the network stack never
    /// completes the request. Bound each attempt so a device listing can retry instead of
    /// remaining in ``DeviceHub/devicesListed``'s finding state forever.
    public static let connectTimeout: Duration = .seconds(15)
    /// How long a socket must stay up before its drop retries from the backoff's start. A
    /// socket the Worker accepts and then closes or stalls at once keeps backing off, so a
    /// struggling service is not redialed every second by every Mac (Leo, 2026-11-27: "That's a
    /// loop that keeps going once it starts, which fits 'worked, then broke super suddenly'").
    public static let stableAfter: Duration = .seconds(30)

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
    let connectTimeout: Duration
    let stableAfter: Duration

    public init(connector: any DeviceHubSocketConnector, pingInterval: Duration = .seconds(60),
                backoff: Backoff = Backoff(initial: .seconds(1), maximum: .seconds(60)),
                connectTimeout: Duration = DeviceHubSocket.connectTimeout,
                stableAfter: Duration = DeviceHubSocket.stableAfter,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.connector = connector
        self.pingInterval = pingInterval
        self.backoff = backoff
        self.connectTimeout = connectTimeout
        self.stableAfter = stableAfter
        self.clock = clock
    }

    /// A stopwatch on `clock`: the returned closure says how long since it was made.
    private static func stopwatch(_ clock: any Clock<Duration>) -> @Sendable () -> Duration {
        func open<C: Clock<Duration>>(_ clock: C) -> @Sendable () -> Duration {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
        return open(clock)
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
                let connection = try await connect()
                await handler(.state(.connected))
                let upFor = Self.stopwatch(clock)
                do { try await serve(connection, handler) } catch {
                    failure = "\(error)"
                    closeCode = (error as? Closed)?.code
                }
                connection.close()
                // Only a socket that stayed up starts the next failure from the backoff's start:
                // one that drops right after connecting keeps the backoff growing.
                if upFor() >= stableAfter { backoff.reset() }
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

    /// Bounds a connector that never completes its upgrade or first-pong wait. Connector
    /// implementations are cancellation-aware, so the losing operation is stopped when the
    /// deadline wins or the socket task is cancelled.
    private func connect() async throws -> any DeviceHubSocketConnection {
        // concurrency-allow: DeviceHubSocketConnector implementations cancel their in-flight
        // URLSession or remote-channel operation when this task is cancelled.
        try await withThrowingTaskGroup(of: (any DeviceHubSocketConnection).self) { group in
            group.addTask { try await self.connector.connect() }
            group.addTask {
                // wakeup-allow: one-shot deadline for a socket connection attempt.
                try await self.clock.sleep(for: self.connectTimeout)
                throw DeviceHubError.transport("socket connect timed out after \(self.connectTimeout)")
            }
            let first: (any DeviceHubSocketConnection)?
            do { first = try await group.next() } catch {
                group.cancelAll()
                throw error
            }
            group.cancelAll()
            // A connection that opened as the deadline fired (or after the winner) is closed, never leaked.
            while !group.isEmpty {
                if let late = try? await group.next() { late.close() }
            }
            guard let first else { throw DeviceHubError.transport("socket connect ended without a result") }
            return first
        }
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
