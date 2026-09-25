public import CmuxMobileRPC
public import CmuxMobileTunnel
import Foundation

/// The native ("On iPhone") browser's network for one paired Mac, with the
/// Mac as the exit point.
///
/// - A SOCKS5 proxy on the phone's loopback. `MacBrowserRoute` decides
///   each destination: the Mac's loopback always rides a tunnel lane on the
///   admitted connection (the Mac connects and relays); any destination the
///   Mac is not allowed to dial loads directly from the phone instead.
/// - iOS never proxies `localhost`/`127.0.0.1`/`::1`, so the Mac's listening
///   loopback ports are mirrored onto the same ports on the phone, each
///   forward also carried by a tunnel lane.
///
/// The phone's loopback is shared with SSH computers' mirrors; every
/// listener goes through `LoopbackPortRegistry` so opening one computer's
/// page takes the port from another computer instead of reaching the wrong
/// machine.
@MainActor
public final class MobileMacBrowserNetwork {
    public typealias OpenLane = @Sendable (_ host: String, _ port: Int) async throws -> any MobileTunnelLaneConnection
    public typealias ListPorts = @Sendable () async throws -> MobileTunnelListeningPorts

    public let macDeviceID: String
    private let openLane: OpenLane
    private let listPorts: ListPorts
    private let registry: LoopbackPortRegistry
    private let direct: any SocksConnectBackend
    private let now: @Sendable () -> ContinuousClock.Instant
    private let exitPolicy = MacTunnelExitPolicy()
    /// Bounds tunnel lanes in flight to this Mac, below the connection's QUIC
    /// stream credit, so browsing can never starve terminal lanes.
    private let lanes = TunnelConcurrencyLimit(limit: MobileMacBrowserNetwork.maximumConcurrentLanes)

    private(set) var proxy: SocksProxyServer?
    private var lastProxyPort: Int?
    private(set) var forwards: [Int: TunnelPortForward] = [:]
    /// Phone ports another socket holds (on the Simulator, often the Mac's
    /// own server): the page reaches those directly.
    private var busyPorts: Set<Int> = []
    private(set) var listing: MobileTunnelListeningPorts?
    private var listedAt: ContinuousClock.Instant?

    /// Tunnel lanes in flight per Mac.
    nonisolated static let maximumConcurrentLanes = 32
    /// Upper bound on mirrored loopback ports.
    nonisolated static let maximumLoopbackForwards = 256
    /// How long a port listing and policy stay fresh for non-loopback loads.
    nonisolated static let listingLifetime: Duration = .seconds(10)

    var registryOwner: String { "mac:\(macDeviceID)" }

    public init(
        macDeviceID: String,
        openLane: @escaping OpenLane,
        listPorts: @escaping ListPorts,
        registry: LoopbackPortRegistry = .shared,
        direct: any SocksConnectBackend = DirectConnectBackend(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.macDeviceID = macDeviceID
        self.openLane = openLane
        self.listPorts = listPorts
        self.registry = registry
        self.direct = direct
        self.now = now
    }

    /// Where connections go, per destination (`MacBrowserRoute`).
    var backend: MacBrowserRouter {
        MacBrowserRouter(
            mac: MacTunnelConnectBackend(openLane: openLane, lanes: lanes),
            direct: direct,
            policy: exitPolicy
        )
    }

    /// Readies the network for a navigation and returns the proxy port: the
    /// proxy, plus (for a `localhost` page) a fresh port listing mirrored
    /// onto the phone.
    public func prepare(loopbackPort: Int?) async throws -> Int {
        let port = try await ensureProxy()
        if let loopbackPort {
            await refreshListing()
            await mirror(ensuring: loopbackPort)
        } else if listedAt.map({ now() - $0 > Self.listingLifetime }) ?? true {
            await refreshListing()
        }
        return port
    }

    /// Stops the proxy and every forward (sign-out, unpair).
    public func stop() async {
        if let proxy {
            registry.release(port: proxy.port, owner: registryOwner)
            await proxy.stop()
        }
        proxy = nil
        let current = forwards
        forwards.removeAll()
        for (port, forward) in current {
            registry.release(port: port, owner: registryOwner)
            await forward.stop()
        }
        busyPorts.removeAll()
    }

    private func ensureProxy() async throws -> Int {
        if let proxy, proxy.isListening { return proxy.port }
        if let stale = proxy {
            registry.release(port: stale.port, owner: registryOwner)
            await stale.stop()
            proxy = nil
            // A dead listener usually means the app was suspended: the phone
            // ports it saw as busy may have changed too.
            busyPorts.removeAll()
        }
        let backend = backend
        let started: SocksProxyServer
        if let preferred = lastProxyPort,
           let rebound = try? await SocksProxyServer.start(backend: backend, port: preferred) {
            started = rebound
        } else {
            started = try await SocksProxyServer.start(backend: backend)
        }
        proxy = started
        lastProxyPort = started.port
        registry.register(port: started.port, owner: registryOwner, pinned: true) {}
        return started.port
    }

    private func refreshListing() async {
        guard let fresh = try? await listPorts() else { return }
        listing = fresh
        listedAt = now()
        exitPolicy.allowsNonLoopbackHosts = fresh.allowsNonLoopbackHosts
    }

    /// Mirrors the Mac's listening loopback ports (the page's own first,
    /// then the rest from 1024 up) onto the same phone ports. Only listed
    /// ports: on the Simulator the phone and the Mac share one loopback, and
    /// forwarding an unlisted port could loop back into the phone's own
    /// listener.
    func mirror(ensuring pagePort: Int) async {
        guard let listing else { return }
        let pinned = registry.pinnedPorts
        let targets = listing.ports.filter { !pinned.contains($0.key) }
        // Forwards whose Mac port stopped listening go away.
        for (port, forward) in forwards where targets[port] == nil || !forward.isListening {
            forwards[port] = nil
            registry.release(port: port, owner: registryOwner)
            await forward.stop()
        }
        let others = targets.keys.filter { $0 >= 1_024 && $0 != pagePort }.sorted()
        let wanted = ([pagePort].filter { targets[$0] != nil } + others).prefix(Self.maximumLoopbackForwards)
        let backend = backend
        for localPort in wanted {
            guard let targetHost = targets[localPort], forwards[localPort] == nil else { continue }
            if busyPorts.contains(localPort), localPort != pagePort { continue }
            guard await registry.evict(port: localPort, for: registryOwner) else { continue }
            do {
                let forward = try await TunnelPortForward.start(
                    backend: backend, targetHost: targetHost, targetPort: localPort, localPort: localPort
                )
                forwards[localPort] = forward
                busyPorts.remove(localPort)
                registry.register(port: localPort, owner: registryOwner) { [weak self] in
                    await self?.dropForward(localPort)
                }
            } catch {
                busyPorts.insert(localPort)
            }
        }
    }

    private func dropForward(_ port: Int) async {
        guard let forward = forwards.removeValue(forKey: port) else { return }
        await forward.stop()
    }
}

/// Where one "On iPhone" connection for a paired Mac goes. The only place
/// the Mac browser network picks between the Mac and the phone's own
/// network.
enum MacBrowserRoute: Equatable, Sendable {
    /// The Mac's own loopback. Only the Mac can reach it (the phone's
    /// loopback is a different machine), so there is no fallback.
    case mac
    /// The Mac advertises that it may dial other hosts: try it, and if its
    /// policy refuses this destination (link-local, metadata, a name that
    /// resolves only to those, or the setting just turned off), load it
    /// from the phone.
    case macThenDirect
    /// The Mac only serves its own loopback: load from the phone.
    case direct

    static func of(host: String, macAllowsNonLoopbackHosts: Bool) -> MacBrowserRoute {
        if TunnelLoopbackHost.isLoopback(host) { return .mac }
        return macAllowsNonLoopbackHosts ? .macThenDirect : .direct
    }
}

/// Opens each connection along its `MacBrowserRoute`.
struct MacBrowserRouter: SocksConnectBackend {
    let mac: any SocksConnectBackend
    let direct: any SocksConnectBackend
    let policy: MacTunnelExitPolicy

    func open(host: String, port: Int) async throws -> any TunnelByteStream {
        switch MacBrowserRoute.of(host: host, macAllowsNonLoopbackHosts: policy.allowsNonLoopbackHosts) {
        case .mac:
            return try await mac.open(host: host, port: port)
        case .direct:
            return try await direct.open(host: host, port: port)
        case .macThenDirect:
            do {
                return try await mac.open(host: host, port: port)
            } catch TunnelOpenError.notAllowed {
                return try await direct.open(host: host, port: port)
            }
        }
    }
}

/// The Mac's advertised policy, read by the proxy's router off the main actor.
final class MacTunnelExitPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var _allowsNonLoopbackHosts = false

    var allowsNonLoopbackHosts: Bool {
        get { lock.withLock { _allowsNonLoopbackHosts } }
        set { lock.withLock { _allowsNonLoopbackHosts = newValue } }
    }
}

/// Opens tunnel connections as lanes to the paired Mac.
struct MacTunnelConnectBackend: SocksConnectBackend {
    let openLane: MobileMacBrowserNetwork.OpenLane
    let lanes: TunnelConcurrencyLimit

    func open(host: String, port: Int) async throws -> any TunnelByteStream {
        guard await lanes.acquire() else { throw TunnelOpenError.unavailable }
        do {
            let lane = try await openLane(host, port)
            return MacTunnelByteStream(lane: lane, lanes: lanes)
        } catch {
            await lanes.release()
            throw Self.openError(error)
        }
    }

    static func openError(_ error: any Error) -> TunnelOpenError {
        switch error as? MobileTunnelOpenFailure {
        case .denied: .notAllowed
        case .refused: .connectionRefused
        case .hostUnreachable, .unresolved: .hostUnreachable
        case .networkUnreachable: .networkUnreachable
        case .timedOut: .timedOut
        case .busy, .unavailable, nil: .unavailable
        }
    }
}

/// A Mac tunnel lane as a relay stream. Closing it returns its lane slot.
final class MacTunnelByteStream: TunnelByteStream, @unchecked Sendable {
    private let lane: any MobileTunnelLaneConnection
    private let lanes: TunnelConcurrencyLimit
    private let lock = NSLock()
    private var released = false

    init(lane: any MobileTunnelLaneConnection, lanes: TunnelConcurrencyLimit) {
        self.lane = lane
        self.lanes = lanes
    }

    func read() async throws -> Data? {
        try await lane.receive(maximumByteCount: 64 * 1024)
    }

    func write(_ data: Data) async throws {
        try await lane.send(data)
    }

    func finishWriting() async {
        await lane.finishSending()
    }

    func close() async {
        await lane.close()
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { await lanes.release() }
    }
}
