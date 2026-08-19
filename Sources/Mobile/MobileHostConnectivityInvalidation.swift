import CmuxPeerTransportCore
import Foundation

/// Revision-only message carried by the account connectivity channel.
///
/// Route material never crosses this channel. A receiver reconciles through
/// the authoritative connectivity sync, so a missing, duplicated, or reordered
/// message changes only how quickly the snapshot is fetched. Ported unchanged
/// from the previous transport's `CmxConnectivityInvalidation`.
struct MobileHostConnectivityInvalidation: Equatable, Sendable {
    private struct Wire: Decodable {
        let type: String
        let protocolVersion: Int
        let revision: UInt64
        let at: UInt64
    }

    static let protocolVersion = 1
    static let maximumFrameBytes = 2_048

    let revision: UInt64
    let acceptedAtMilliseconds: UInt64

    init(revision: UInt64, acceptedAtMilliseconds: UInt64) {
        self.revision = revision
        self.acceptedAtMilliseconds = acceptedAtMilliseconds
    }

    /// Strictly parses the small, enumerable invalidation wire shape.
    static func parse(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumFrameBytes,
              let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(object.keys) == Set(["type", "protocolVersion", "revision", "at"]),
              let wire = try? JSONDecoder().decode(Wire.self, from: data),
              wire.type == "connectivity.invalidate",
              wire.protocolVersion == protocolVersion,
              wire.revision > 0
        else {
            throw MobileHostConnectivityInvalidationError.invalidFrame
        }
        return Self(
            revision: wire.revision,
            acceptedAtMilliseconds: wire.at
        )
    }
}

enum MobileHostConnectivityInvalidationError: Error, Equatable, Sendable {
    case invalidServiceURL
    case notAuthenticated
    case invalidFrame
}

/// Maintains the quiet account-scoped WebSocket used by both Apple runtimes.
///
/// The caller owns account lifecycle by calling ``start()`` and ``stop()``.
/// Tokens are read for every reconnect, streams are bounded by the worker to
/// token expiry, and cancellation closes a suspended receive immediately.
actor MobileHostConnectivityInvalidationSubscriber {
    typealias AccessTokenProvider = @Sendable () async -> String?
    typealias Handler = @Sendable (MobileHostConnectivityInvalidation) async -> Void

    private enum StreamOutcome {
        case served
        case failed
    }

    private let serviceBaseURL: URL
    private let accessToken: AccessTokenProvider
    private let session: URLSession
    private var backoff: PeerReconnectBackoff
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let handler: Handler
    private var loopTask: Task<Void, Never>?

    init(
        serviceBaseURL: URL,
        accessToken: @escaping AccessTokenProvider,
        session: sending URLSession = .shared,
        backoff: PeerReconnectBackoff = PeerReconnectBackoff(profile: .foregroundClient),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task<Never, Never>.sleep(for: .seconds($0))
        },
        handler: @escaping Handler
    ) {
        self.serviceBaseURL = serviceBaseURL
        self.accessToken = accessToken
        self.session = session
        self.backoff = backoff
        self.sleep = sleep
        self.handler = handler
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    func stop() async {
        let task = loopTask
        loopTask = nil
        task?.cancel()
        await task?.value
    }

    /// Converts a configured HTTP(S) service origin into its WebSocket route.
    static func subscribeURL(serviceBaseURL: URL) -> URL? {
        guard var components = URLComponents(
            url: serviceBaseURL,
            resolvingAgainstBaseURL: false
        ) else { return nil }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }
        let path = components.path.hasSuffix("/")
            ? String(components.path.dropLast())
            : components.path
        components.path = path + "/v1/connectivity/subscribe"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Re-subscribe cadence comes from the one shared reconnect ladder
    /// (`PeerReconnectBackoff`) instead of a private exponential schedule:
    /// failures draw a decorrelated-jittered delay bounded by the 30 s
    /// foreground cap, and a served stream resets to the floor window, so the
    /// jittered draw spreads a fleet's re-subscribes when a service deploy
    /// closes every socket at once.
    private func run() async {
        while !Task.isCancelled {
            let outcome = await subscribeOnce()
            guard !Task.isCancelled else { return }
            if outcome == .served {
                backoff.reset()
            }
            let delay = backoff.nextDelay()
            let seconds = TimeInterval(delay.components.seconds)
                + TimeInterval(delay.components.attoseconds) / 1e18
            guard (try? await sleep(seconds)) != nil else { return }
        }
    }

    private func subscribeOnce() async -> StreamOutcome {
        guard let url = Self.subscribeURL(serviceBaseURL: serviceBaseURL) else {
            return .failed
        }
        guard let token = await accessToken(), !token.isEmpty else {
            return .failed
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = MobileHostConnectivityInvalidation.maximumFrameBytes
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let clock = ContinuousClock()
        let startedAt = clock.now
        var delivered = false
        return await withTaskCancellationHandler {
            while !Task.isCancelled {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    if delivered { return .served }
                    let closedCleanly = task.closeCode == .normalClosure
                        || task.closeCode == .goingAway
                    return closedCleanly && clock.now - startedAt >= .seconds(60)
                        ? .served
                        : .failed
                }
                let data: Data
                switch message {
                case let .string(text):
                    data = Data(text.utf8)
                case let .data(bytes):
                    data = bytes
                @unknown default:
                    return .failed
                }
                guard let invalidation = try? MobileHostConnectivityInvalidation.parse(data) else {
                    return .failed
                }
                guard !Task.isCancelled else { return .served }
                delivered = true
                await handler(invalidation)
            }
            return .served
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }
}
