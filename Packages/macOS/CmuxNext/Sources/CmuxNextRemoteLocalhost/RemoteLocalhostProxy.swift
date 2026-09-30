import Foundation
import CmuxNextWakeups
import Network
import Synchronization
import os

/// The in-process HTTP proxy that remote-localhost browser stores use
/// (plans/cmux-next/remote-localhost.md section 5).
///
/// Each machine gets its own listener on a random 127.0.0.1 port
/// (`listen(for:route:)`), which is the port its Chromium store's proxy
/// setting names. A connection there is accepted only from this process or
/// its children (`PeerProcess`: the Chromium helpers), because Chrome-style
/// CEF never asks the embedder for proxy credentials. Requests must be in
/// proxy form (CONNECT or absolute URL), which a page cannot produce.
///
/// `start` opens one more listener for clients that authenticate with a
/// route credential instead (a random user name per machine, one per-launch
/// secret); anything else gets `407`.
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
        /// Per-machine listeners, by machine key, and their routes by port.
        var machineListeners: [String: (listener: NWListener, port: UInt16)] = [:]
        var routesByPort: [UInt16: Route] = [:]
        var stats = Stats()
        /// Recent outcomes, newest last (`debug.remote-localhost`).
        var events: [String] = []
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

    /// The last 32 connection outcomes (no credentials, no payload).
    public var recentEvents: [String] { state.withLock(\.events) }

    func note(_ event: String) {
        state.withLock { state in
            state.events.append(event)
            if state.events.count > 32 { state.events.removeFirst(state.events.count - 32) }
        }
    }

    /// Binds the credential listener on a random 127.0.0.1 port
    /// (idempotent) and returns it.
    public func start() async throws(StartError) -> UInt16 {
        if let port { return port }
        let (listener, port) = try await bind(route: nil)
        state.withLock { state in
            state.listener = listener
            state.port = port
        }
        logger.info("remote-localhost proxy on 127.0.0.1:\(port)")
        return port
    }

    /// The port of `machine`'s own listener, bound on first use; the
    /// route's opener is replaced on every call.
    public func listen(for machine: String, route: Route) async throws(StartError) -> UInt16 {
        let existing: UInt16? = state.withLock { state in
            guard let port = state.machineListeners[machine]?.port else { return nil }
            state.routesByPort[port] = route
            return port
        }
        if let existing { return existing }
        let (listener, port) = try await bind(route: route)
        let winner: UInt16 = state.withLock { state in
            if let port = state.machineListeners[machine]?.port { return port }
            state.machineListeners[machine] = (listener, port)
            state.routesByPort[port] = route
            return port
        }
        if winner != port { listener.cancel() }
        logger.info("remote-localhost proxy for \(route.machineName, privacy: .public) on 127.0.0.1:\(winner)")
        return winner
    }

    /// Machine listener ports by machine key (`debug.remote-localhost`).
    public var machinePorts: [String: UInt16] { state.withLock { $0.machineListeners.mapValues(\.port) } }

    /// The route of a machine listener's port, nil for the credential listener.
    func route(forListenerPort port: UInt16) -> Route? {
        state.withLock { $0.routesByPort[port] }
    }

    private func bind(route: Route?) async throws(StartError) -> (NWListener, UInt16) {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw .listener(String(describing: error))
        }
        let machine = route != nil
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let port = listener?.port?.rawValue else {
                connection.cancel()
                return
            }
            self.accept(connection, localPort: port, machineListener: machine)
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
            return (listener, port)
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
        let listeners: [NWListener] = state.withLock { state in
            defer {
                state.listener = nil
                state.port = nil
                state.machineListeners.removeAll()
                state.routesByPort.removeAll()
            }
            return [state.listener].compactMap(\.self) + state.machineListeners.values.map(\.listener)
        }
        for listener in listeners { listener.cancel() }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection, localPort: UInt16, machineListener: Bool) {
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
        ProxyConnection(client: connection, proxy: self, localPort: localPort, machineListener: machineListener).start()
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
