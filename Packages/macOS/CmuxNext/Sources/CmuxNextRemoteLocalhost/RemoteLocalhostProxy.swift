import Foundation
import CmuxNextWakeups
import Network
import Synchronization
import os

/// The in-process HTTP proxy that remote-localhost browser stores use
/// (plans/cmux-next/remote-localhost.md section 5).
///
/// It listens on a random 127.0.0.1 port and accepts only requests that
/// carry one of its routes' credentials: each machine gets a random user
/// name, and every route shares one per-launch secret. Chromium answers the
/// proxy challenge through the shim (`GetAuthCredentials`), so a page never
/// sees the credentials, and another local user or process gets `407`.
///
/// Loopback destinations open a tunnel to the route's machine. Every other
/// destination connects directly from this Mac, and a connection whose peer
/// is this Mac's loopback is refused (DNS rebinding toward this Mac).
public final class RemoteLocalhostProxy: Sendable {
    /// One machine a browser store routes to.
    public struct Route: Sendable {
        public var machineName: String
        public var opener: any LoopbackTunnelOpening

        public init(machineName: String, opener: any LoopbackTunnelOpening) {
            self.machineName = machineName
            self.opener = opener
        }
    }

    /// Counters for `debug.remote-localhost`.
    public struct Stats: Sendable, Equatable {
        public var accepted = 0
        public var unauthorized = 0
        public var tunnels = 0
        public var direct = 0
        public var refusedLocal = 0
        public var failures = 0
        public var open = 0
    }

    public enum StartError: Error, Sendable {
        case listener(String)
    }

    private struct State {
        var listener: NWListener?
        var port: UInt16?
        /// Route by user name.
        var routes: [String: Route] = [:]
        /// User name by machine key (stable for the launch).
        var usernames: [String: String] = [:]
        var stats = Stats()
    }

    private let state = Mutex(State())
    private let secret: String
    let queue = DispatchQueue(label: "com.cmuxterm.next.remote-localhost", qos: .userInitiated)
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-localhost")
    /// Open connections, capped so a flood cannot exhaust descriptors.
    static let maxConnections = 256

    public init(secret: String = ProxyCredential.randomToken(bytes: 32)) {
        self.secret = secret
    }

    /// The listening port once `start` returned.
    public var port: UInt16? { state.withLock(\.port) }

    public var stats: Stats { state.withLock(\.stats) }

    /// Binds 127.0.0.1 on a random port (idempotent) and returns it.
    public func start() async throws(StartError) -> UInt16 {
        if let port { return port }
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .listener(String(describing: error))
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            self.accept(connection)
        }
        let result: Result<UInt16, StartError> = await withCheckedContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { update in
                let outcome: Result<UInt16, StartError>?
                switch update {
                case .ready: outcome = listener.port.map { .success($0.rawValue) } ?? .failure(.listener("no port"))
                case .failed(let error): outcome = .failure(.listener(String(describing: error)))
                case .cancelled: outcome = .failure(.listener("cancelled"))
                default: outcome = nil
                }
                guard let outcome, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(returning: outcome)
            }
            listener.start(queue: queue)
        }
        switch result {
        case .success(let port):
            state.withLock { state in
                state.listener = listener
                state.port = port
            }
            logger.info("remote-localhost proxy on 127.0.0.1:\(port)")
            return port
        case .failure(let error):
            listener.cancel()
            throw error
        }
    }

    /// The credential of `machine`'s route, created on first use and
    /// replaced (same user name) when the opener changes.
    public func credential(for machine: String, route: Route) -> ProxyCredential {
        let username: String = state.withLock { state in
            let username = state.usernames[machine] ?? ProxyCredential.randomToken(bytes: 16)
            state.usernames[machine] = username
            state.routes[username] = route
            return username
        }
        return ProxyCredential(username: username, password: secret)
    }

    /// Drops `machine`'s route; its store gets `407` until registered again.
    public func removeRoute(for machine: String) {
        state.withLock { state in
            if let username = state.usernames[machine] { state.routes[username] = nil }
        }
    }

    public func stop() {
        let listener: NWListener? = state.withLock { state in
            defer {
                state.listener = nil
                state.port = nil
            }
            return state.listener
        }
        listener?.cancel()
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let admitted = state.withLock { state -> Bool in
            guard state.stats.open < Self.maxConnections else { return false }
            state.stats.open += 1
            state.stats.accepted += 1
            return true
        }
        guard admitted else {
            connection.cancel()
            return
        }
        ProxyConnection(client: connection, proxy: self).start()
    }

    func connectionEnded() {
        state.withLock { $0.stats.open -= 1 }
    }

    func count(_ keyPath: WritableKeyPath<Stats, Int>) {
        state.withLock { $0.stats[keyPath: keyPath] += 1 }
    }

    /// The route whose credential is `authorization` (a `Basic` value).
    func route(forAuthorization authorization: String?) -> Route? {
        guard let authorization, authorization.hasPrefix("Basic "),
              let decoded = Data(base64Encoded: String(authorization.dropFirst(6))),
              let text = String(data: decoded, encoding: .utf8),
              let colon = text.firstIndex(of: ":") else { return nil }
        let username = String(text[..<colon]), password = String(text[text.index(after: colon)...])
        guard ProxyCredential.constantTimeEqual(password, secret) else { return nil }
        return state.withLock { $0.routes[username] }
    }
}
