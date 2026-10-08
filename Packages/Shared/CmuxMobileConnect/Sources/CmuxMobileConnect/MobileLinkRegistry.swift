public import CmuxLink
public import CmuxLinkDirect
import CmuxLinkWebRTC
import CmuxLinkWebRTCUnderlay
import CmuxLinkWG
public import CmuxMobileLink
import Foundation

/// The phone's links to its trusted Macs (d1-terminal-ux.md section 2): one
/// `MobileLinkClient` per reachable Mac, each over a `PathSelector` of B4's
/// `DirectCarrier`, B2's `WebRTCCarrier` and (DEV switch) B3's
/// `WireGuardOverWebRTCCarrier`, gated by the Mac's `MobileCarrierPlan`.
/// The plan can force one of the V1 carriers for live dogfood.
///
/// Owns the clients it makes: a Mac that leaves the trust store, or whose
/// pinned keys change, loses its client (closed, so its terminals end).
/// Endpoint changes (Bonjour, synced direct hosts) and path snapshots only
/// update the plan and restart the race; live sessions keep running.
@MainActor
public final class MobileLinkRegistry {
    /// The Mac's signaling relay; `route.team` names another account's Mac.
    public typealias SignalingFactory = @Sendable (_ route: MobileHostRoute) -> MobileHostSignaling?

    private struct Entry {
        var route: MobileHostRoute
        let client: MobileLinkClient
        let plan: MobileCarrierPlan
        let webrtc: WebRTCCarrier?
        let signaling: MobileHostSignaling?
        let badgeTask: Task<Void, Never>
    }

    private let credentials: MobileDeviceCredentials
    private let options: MobileConnectOptions
    private let signaling: SignalingFactory
    private var entries: [String: Entry] = [:]
    private var snapshot: DirectPathSnapshot?
    private var badges: [String: PathBadge] = [:]
    private var badgeSubscribers: [UUID: AsyncStream<[String: PathBadge]>.Continuation] = [:]
    private var closed = false

    public init(credentials: MobileDeviceCredentials, options: MobileConnectOptions = MobileConnectOptions(),
                snapshot: DirectPathSnapshot? = nil, signaling: @escaping SignalingFactory) {
        self.credentials = credentials
        self.options = options
        self.snapshot = snapshot
        self.signaling = signaling
    }

    /// Macs with a client, sorted.
    public var hostIDs: [String] { entries.keys.sorted() }

    public func client(for hostID: String) -> MobileLinkClient? { entries[hostID]?.client }

    public func route(for hostID: String) -> MobileHostRoute? { entries[hostID]?.route }

    /// The carriers a Mac's next race may use (diagnostics, tests).
    public func plan(for hostID: String) -> MobileCarrierPlan? { entries[hostID]?.plan }

    /// Replaces the set of trusted Macs.
    public func update(routes: [MobileHostRoute]) {
        guard !closed else { return }
        let wanted = Dictionary(routes.map { ($0.hostID, $0) }, uniquingKeysWith: { first, _ in first })
        for (host, entry) in entries {
            guard let route = wanted[host], route.pinsSameKeys(as: entry.route), isReachable(route) else {
                remove(host)
                continue
            }
            entries[host]?.route = route
            entry.plan.update(endpoints: route.directEndpoints)
        }
        for (host, route) in wanted where entries[host] == nil && isReachable(route) {
            entries[host] = makeEntry(route)
        }
    }

    /// NWPathMonitor reported a change: every plan sees the new snapshot,
    /// WebRTC restarts ICE, and every session races again at once.
    public func pathDidChange(_ snapshot: DirectPathSnapshot) {
        guard !closed else { return }
        self.snapshot = snapshot
        for entry in entries.values {
            entry.plan.update(snapshot: snapshot)
            let client = entry.client
            let webrtc = entry.webrtc
            Task {
                await webrtc?.networkDidChange()
                await client.networkDidChange()
            }
        }
    }

    /// The live path badge per Mac, newest first.
    public func pathBadges() -> AsyncStream<[String: PathBadge]> {
        let (stream, continuation) = AsyncStream<[String: PathBadge]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        badgeSubscribers[id] = continuation
        continuation.yield(badges)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.badgeSubscribers[id] = nil }
        }
        return stream
    }

    /// Closes every client (sign-out, account switch). Final.
    public func close() {
        closed = true
        for host in Array(entries.keys) { remove(host) }
        for continuation in badgeSubscribers.values { continuation.finish() }
        badgeSubscribers.removeAll()
    }

    // MARK: Private

    private func isReachable(_ route: MobileHostRoute) -> Bool {
        switch options.transport {
        case .direct:
            return route.directHostKey != nil && !route.directEndpoints.isEmpty
        case .webrtc:
            return (route.webrtcHostKey != nil && credentials.webrtc != nil)
                || (options.wireGuardOverWebRTC && route.wireGuardHostKey != nil && credentials.wireGuard != nil)
        case .automatic:
            return (route.directHostKey != nil && !route.directEndpoints.isEmpty)
                || (route.webrtcHostKey != nil && credentials.webrtc != nil)
                || (options.wireGuardOverWebRTC && route.wireGuardHostKey != nil && credentials.wireGuard != nil)
        }
    }

    private func makeEntry(_ route: MobileHostRoute) -> Entry {
        let plan = MobileCarrierPlan(endpoints: route.directEndpoints, snapshot: snapshot,
                                     transport: options.transport)
        var carriers: [any LinkCarrier] = []
        if options.transport != .webrtc, route.directHostKey != nil {
            carriers.append(DirectCarrier(identity: credentials.direct, resolver: plan, routes: plan))
        }
        let needsSignaling = options.transport != .direct && ((route.webrtcHostKey != nil && credentials.webrtc != nil)
            || (options.wireGuardOverWebRTC && route.wireGuardHostKey != nil && credentials.wireGuard != nil))
        let relay = needsSignaling ? signaling(route) : nil
        var webrtc: WebRTCCarrier?
        if let relay, route.webrtcHostKey != nil, let identity = credentials.webrtc {
            let carrier = WebRTCCarrier(router: relay.router, iceServers: relay.iceServers, identity: identity,
                                        configuration: options.webrtc)
            webrtc = carrier
            carriers.append(carrier)
        }
        if let relay, options.wireGuardOverWebRTC, route.wireGuardHostKey != nil, let key = credentials.wireGuard {
            let dialer = WebRTCDatagramDialer(router: relay.router, iceServers: relay.iceServers, configuration: options.webrtc)
            carriers.append(WireGuardOverWebRTCCarrier(identity: key, installID: credentials.signer.install,
                                                       underlays: WebRTCUnderlayDialer(dialer: dialer),
                                                       configuration: options.wireGuard))
        }
        let selector = PathSelector(carriers: carriers.map { PlannedCarrier($0, plan: plan) }, policy: options.policy)
        let peer = route.peer
        let link = options.link
        let client = MobileLinkClient(hostID: route.hostID, signer: credentials.signer, client: credentials.client,
                                      makeSession: { LinkSession(peer: peer, selector: selector, configuration: link) })
        let host = route.hostID
        let badgeTask = Task { [weak self] in
            for await badge in await client.pathBadges() {
                guard !Task.isCancelled else { return }
                self?.setBadge(badge, for: host)
            }
        }
        return Entry(route: route, client: client, plan: plan, webrtc: webrtc, signaling: relay, badgeTask: badgeTask)
    }

    private func remove(_ host: String) {
        guard let entry = entries.removeValue(forKey: host) else { return }
        entry.badgeTask.cancel()
        let client = entry.client
        let relay = entry.signaling
        Task {
            await client.close()
            await relay?.close()
        }
        if badges.removeValue(forKey: host) != nil { publishBadges() }
    }

    private func setBadge(_ badge: PathBadge, for host: String) {
        guard entries[host] != nil, badges[host] != badge else { return }
        badges[host] = badge
        publishBadges()
    }

    private func publishBadges() {
        for continuation in badgeSubscribers.values { continuation.yield(badges) }
    }
}
