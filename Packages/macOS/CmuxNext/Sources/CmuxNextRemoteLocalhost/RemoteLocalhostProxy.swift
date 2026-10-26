import Foundation
import CmuxNextWakeups
import Network
import CmuxNextCompat
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
        /// Whether non-loopback proxy targets may connect from this Mac.
        public var allowsDirectDestinations: Bool

        public init(
            machineName: String,
            opener: any LoopbackTunnelOpening,
            allowsDirectDestinations: Bool = true
        ) {
            self.machineName = machineName
            self.opener = opener
            self.allowsDirectDestinations = allowsDirectDestinations
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
        /// Latest externally owned route generation by machine key.
        var routeVersions: [String: RouteVersion] = [:]
        var stats = Stats()
        /// Recent outcomes, newest last (`debug.remote-localhost`).
        var events: [String] = []
        /// `host:port` addresses whose tunnel found the machine not connected, by listener port
        /// (``takeStranded(listenerPort:)``).
        var stranded: [UInt16: Set<String>] = [:]
    }

    private struct RouteVersion: Comparable {
        var incarnation: UInt64
        var generation: UInt64

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.incarnation == rhs.incarnation
                ? lhs.generation < rhs.generation
                : lhs.incarnation < rhs.incarnation
        }
    }

    private let state = Mutex(State())
    private let secret: String
    let queue = DispatchQueue(label: "com.cmuxterm.next.remote-localhost", qos: .userInitiated)
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "remote-localhost")
    /// Open connections, capped so a flood cannot exhaust descriptors.
    static let maxConnections = 256

    /// The endpoint a direct destination connects to. Tests map a name to
    /// this Mac's loopback to stand in for DNS rebinding.
    let directHost: @Sendable (String) -> NWEndpoint.Host

    public convenience init(secret: String = ProxyCredential.randomToken(bytes: 32)) {
        self.init(secret: secret, directHost: { NWEndpoint.Host($0) })
    }

    init(secret: String = ProxyCredential.randomToken(bytes: 32), directHost: @escaping @Sendable (String) -> NWEndpoint.Host) {
        self.secret = secret
        self.directHost = directHost
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
        try await listen(for: machine, version: nil, route: route)
    }

    /// The peer-checked listener for a versioned external route. A delayed
    /// older answer returns the listener but never replaces its newer opener.
    public func listen(
        for machine: String,
        incarnation: UInt64,
        generation: UInt64,
        route: Route
    ) async throws(StartError) -> UInt16 {
        try await listen(
            for: machine,
            version: RouteVersion(incarnation: incarnation, generation: generation),
            route: route
        )
    }

    private func listen(for machine: String, version: RouteVersion?, route: Route) async throws(StartError) -> UInt16 {
        let existing: UInt16? = state.withLock { state in
            guard let port = state.machineListeners[machine]?.port else { return nil }
            let current = state.routeVersions[machine]
            if Self.shouldInstall(version, over: current) {
                state.routesByPort[port] = route
                if let version { state.routeVersions[machine] = version }
            }
            return port
        }
        if let existing { return existing }
        let (listener, port) = try await bind(route: route)
        let winner: UInt16 = state.withLock { state in
            if let existing = state.machineListeners[machine]?.port {
                let current = state.routeVersions[machine]
                if Self.shouldInstall(version, over: current) {
                    state.routesByPort[existing] = route
                    if let version { state.routeVersions[machine] = version }
                }
                return existing
            }
            state.machineListeners[machine] = (listener, port)
            state.routesByPort[port] = route
            if let version { state.routeVersions[machine] = version }
            return port
        }
        if winner != port { listener.cancel() }
        logger.info("remote-localhost proxy for \(route.machineName, privacy: .public) on 127.0.0.1:\(winner)")
        return winner
    }

    private static func shouldInstall(_ version: RouteVersion?, over current: RouteVersion?) -> Bool {
        guard let version, let current else { return true }
        return version >= current
    }

    /// Machine listener ports by machine key (`debug.remote-localhost`).
    public var machinePorts: [String: UInt16] { state.withLock { $0.machineListeners.mapValues(\.port) } }

    /// Notes that a request for `host:port` on listener `listenerPort` found the machine not
    /// connected (its link down at launch or since): the page it got is an error page.
    func noteStranded(listenerPort: UInt16, host: String, port: UInt16) {
        state.withLock { state in
            var addresses = state.stranded[listenerPort, default: []]
            guard addresses.count < 64 else { return }
            addresses.insert(Self.address(host: host, port: port))
            state.stranded[listenerPort] = addresses
        }
    }

    /// The `host:port` addresses (``address(host:port:)``) that machine listener `listenerPort`
    /// answered with "not connected" since the last call, forgotten by this call: when the machine
    /// connects again, its pages that show that error load again (#25595).
    public func takeStranded(listenerPort: UInt16) -> Set<String> {
        state.withLock { $0.stranded.removeValue(forKey: listenerPort) ?? [] }
    }

    /// `host:port` with a lowercase host and IPv6 literals in brackets, as ``takeStranded(listenerPort:)`` answers.
    public static func address(host: String, port: UInt16) -> String {
        let host = host.lowercased()
        return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// The route of a machine listener's port, nil for the credential listener.
    public func route(forListenerPort port: UInt16) -> Route? {
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
                state.routeVersions.removeAll()
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
