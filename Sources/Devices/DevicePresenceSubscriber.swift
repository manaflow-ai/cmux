import Foundation

/// Subscribes this Mac to the account's live presence stream
/// (`GET /v1/presence/subscribe` on `workers/presence`, WebSocket), the same
/// stream the iOS device tree renders from. Every subscribe delivers a
/// snapshot first, then online/offline/seen/routes transitions; the same socket
/// also serves the `devices` sync collection after a `sync.hello`, which is
/// where device owners come from.
///
/// One instance is one session: `subscribe()` opens the socket and yields
/// parsed frames until the server closes it (streams are deadline-bounded by
/// the token, 15 minutes at most) or the transport fails. Reconnect and
/// backoff belong to the owner (``DeviceDirectory``), which also decides when a
/// session should exist at all.
actor DevicePresenceSubscriber {
    enum SubscribeError: Error, Equatable {
        case invalidServiceURL
        case notAuthenticated
        /// The bounded buffer dropped a frame; the protocol is snapshot+delta,
        /// so the consumer must resubscribe rather than render past a gap.
        case framesDropped
        case keepaliveTimedOut
    }

    struct Credentials: Sendable {
        let accessToken: String
        let teamID: String?
    }

    private let serviceBaseURL: URL
    private let credentials: @Sendable () async throws -> Credentials?
    private let session: URLSession
    private let clock: any Clock<Duration>

    init(
        serviceBaseURL: URL,
        session: URLSession = .shared,
        clock: any Clock<Duration> = ContinuousClock(),
        credentials: @escaping @Sendable () async throws -> Credentials?
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.session = session
        self.clock = clock
        self.credentials = credentials
    }

    /// The WebSocket subscribe URL for a service base URL; nil when the base is
    /// not http(s)/ws(s). Pure for tests.
    static func subscribeURL(serviceBaseURL: URL) -> URL? {
        guard var comps = URLComponents(url: serviceBaseURL, resolvingAgainstBaseURL: false) else { return nil }
        switch comps.scheme?.lowercased() {
        case "https": comps.scheme = "wss"
        case "wss": break
        case "http", "ws":
            #if DEBUG
            guard let host = comps.host?.lowercased(), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) else { return nil }
            comps.scheme = "ws"
            #else
            return nil
            #endif
        default: return nil
        }
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + "/v1/presence/subscribe"
        return comps.url
    }

    /// Opens one subscribe session and sends the `devices` sync hello.
    func subscribe() async throws -> AsyncThrowingStream<DevicePresenceFrame, any Error> {
        guard let url = Self.subscribeURL(serviceBaseURL: serviceBaseURL) else {
            throw SubscribeError.invalidServiceURL
        }
        guard let credentials = try await credentials() else {
            throw SubscribeError.notAuthenticated
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let teamID = credentials.teamID, !teamID.isEmpty {
            request.setValue(teamID, forHTTPHeaderField: "X-Cmux-Team-Id")
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        // Sent before the first receive so the owner-carrying `devices`
        // snapshot arrives beside the presence snapshot instead of trailing it.
        let hello = String(decoding: DevicePresenceFrame.syncHello(), as: UTF8.self)
        try await task.send(.string(hello))

        let clock = clock
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            // A dead network path may never complete receive(). Ping on a
            // cancellable cadence and close the socket if a pong misses its deadline.
            let keepalive = Task {
                do {
                    while !Task.isCancelled {
                        try await clock.sleep(for: .seconds(30))
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask {
                                // Foundation exposes pong delivery through a
                                // one-shot callback; bridge it at this boundary.
                                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                                    task.sendPing { error in
                                        if let error { continuation.resume(throwing: error) }
                                        else { continuation.resume() }
                                    }
                                }
                            }
                            group.addTask {
                                try await clock.sleep(for: .seconds(10))
                                task.cancel(with: .goingAway, reason: nil)
                                throw SubscribeError.keepaliveTimedOut
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                    task.cancel(with: .goingAway, reason: nil)
                }
            }
            let receiveLoop = Task {
                do {
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
                        let frame: DevicePresenceFrame
                        do {
                            frame = try DevicePresenceFrame.parse(data)
                        } catch {
                            continue
                        }
                        switch continuation.yield(frame) {
                        case .enqueued:
                            break
                        case .dropped:
                            continuation.finish(throwing: SubscribeError.framesDropped)
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
                keepalive.cancel()
                receiveLoop.cancel()
                task.cancel(with: .goingAway, reason: nil)
            }
        }
    }
}
