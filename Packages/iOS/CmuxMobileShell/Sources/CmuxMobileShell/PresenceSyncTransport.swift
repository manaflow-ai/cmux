public import CmuxSyncStore
public import Foundation

/// A cursor-safe sync/v1 transport over an authenticated presence WebSocket.
///
/// The device-list stream is intentionally a separate socket from the presence
/// overlay. Presence traffic can be high volume and is allowed to reconnect or
/// be filtered independently, while this stream must preserve every sync frame
/// in order until ``SyncClient`` commits its cursor. The server sends presence
/// frames on this socket too; ``SyncClient`` treats those frames as noise.
public actor PresenceSyncTransport: SyncTransport {
    private let serviceBaseURL: String
    private let tokenSource: PresenceTokenSource
    private let expectedUserID: String?
    private let teamID: String
    private let session: URLSession
    private let livenessInterval: Duration
    private let pingTimeout: Duration
    private let livenessClock: any Clock<Duration>
    private var task: URLSessionWebSocketTask?

    /// Creates an authenticated, team-scoped sync transport.
    ///
    /// - Parameters:
    ///   - serviceBaseURL: Presence service origin, without a required trailing slash.
    ///   - tokenSource: Supplies a token for the current Stack account.
    ///   - expectedUserID: Account captured by the sync attempt. Token reads fail
    ///     closed if auth changes while the socket is opening.
    ///   - teamID: Verified team scope to send in `X-Cmux-Team-Id`.
    ///   - session: URL session that owns the WebSocket task.
    ///   - livenessInterval: Idle interval between protocol pings.
    ///   - pingTimeout: Maximum time a ping may remain unanswered before reconnect.
    ///   - livenessClock: Clock used by ping cadence and timeout sleeps.
    public init(
        serviceBaseURL: String,
        tokenSource: PresenceTokenSource,
        expectedUserID: String? = nil,
        teamID: String,
        session: sending URLSession = .shared,
        livenessInterval: Duration = .seconds(20),
        pingTimeout: Duration = .seconds(10),
        livenessClock: any Clock<Duration> = ContinuousClock()
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.tokenSource = tokenSource
        self.expectedUserID = expectedUserID
        self.teamID = teamID
        self.session = session
        self.livenessInterval = livenessInterval
        self.pingTimeout = pingTimeout
        self.livenessClock = livenessClock
    }

    public func send(_ data: Data) async throws {
        let task = try await connectedTask()
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public nonisolated func frames() -> AsyncThrowingStream<Data, any Error> {
        // Never drop the oldest frame. Sync cursors are contiguous-prefix
        // watermarks, so dropping a frame in the middle and then applying a
        // later delta would permanently skip the missing revision. Ending the
        // stream on overflow lets the caller reconnect from the last committed
        // cursor and replay the dropped tail.
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let pump = Task {
                do {
                    let task = try await self.connectedTask()
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            while !Task.isCancelled {
                                let message = try await task.receive()
                                let data: Data
                                switch message {
                                case .string(let text):
                                    data = Data(text.utf8)
                                case .data(let raw):
                                    data = raw
                                @unknown default:
                                    continue
                                }
                                switch continuation.yield(data) {
                                case .enqueued:
                                    break
                                case .dropped:
                                    throw PresenceClientError.updatesDropped
                                case .terminated:
                                    return
                                @unknown default:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            while !Task.isCancelled {
                                try await self.livenessClock.sleep(for: self.livenessInterval)
                                try await self.sendPing(task)
                            }
                        }
                        try await group.next()
                        group.cancelAll()
                        try await group.waitForAll()
                    }
                    continuation.finish()
                } catch {
                    await self.close()
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
        guard let accessToken = await tokenSource.accessToken(expectedUserID: expectedUserID) else {
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

    /// URLSession does not reliably surface a half-open WebSocket through
    /// `receive()` when neither side sends application data. A protocol ping
    /// turns that silent failure into a bounded error, so the shell's existing
    /// reconnect loop can re-hello from its durable cursor without a relaunch.
    private func sendPing(_ task: URLSessionWebSocketTask) async throws {
        let clock = livenessClock
        let timeout = pingTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.sendPingOnce(task)
            }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    @concurrent
    nonisolated private static func sendPingOnce(
        _ task: URLSessionWebSocketTask
    ) async throws {
        try await awaitPingCallback(
            { completion in
                task.sendPing(pongReceiveHandler: completion)
            },
            onCancel: {
                task.cancel(with: .goingAway, reason: nil)
            }
        )
    }

    nonisolated static func awaitPingCallback(
        _ start: @escaping @Sendable (@escaping @Sendable ((any Error)?) -> Void) -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                start { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            onCancel()
        }
    }
}
