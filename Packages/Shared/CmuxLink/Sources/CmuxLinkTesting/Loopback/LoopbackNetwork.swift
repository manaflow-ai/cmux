import CmuxLink

/// An in-process network: carriers made from it connect to its acceptor.
/// Fault hooks drive the conformance suite: refuse connects, drop every live
/// transport, move live transports to another path, and roam.
public actor LoopbackNetwork {
    /// The first acceptor. `replaceAcceptor()` simulates a host restart.
    public nonisolated let acceptor: LoopbackAcceptor
    private var activeAcceptor: LoopbackAcceptor
    private let clock: LinkClock
    private var conditions: NetworkConditions?
    private var pipes: [LoopbackPipe] = []
    private var carrierPaths: [CarrierKind: PathKind] = [:]
    private var refusing: Set<CarrierKind> = []
    private var connectDelays: [CarrierKind: Duration] = [:]
    private var connectCounts: [CarrierKind: Int] = [:]

    public init(conditions: NetworkConditions? = nil, clock: LinkClock = .continuous) {
        let acceptor = LoopbackAcceptor()
        self.acceptor = acceptor
        self.activeAcceptor = acceptor
        self.conditions = conditions
        self.clock = clock
    }

    /// A carrier that produces `path` (or the path set by `roam`).
    public nonisolated func carrier(
        kind: CarrierKind,
        path: PathKind,
        candidatePaths: [PathKind]? = nil,
        capabilities: TransportCapabilities = .stream
    ) -> LoopbackCarrier {
        LoopbackCarrier(
            network: self, kind: kind, defaultPath: path,
            candidatePaths: candidatePaths ?? [path], capabilities: capabilities
        )
    }

    /// Applies to live transports and later connects.
    public func setConditions(_ conditions: NetworkConditions?) async {
        self.conditions = conditions
        for pipe in pipes { await pipe.setConditions(conditions) }
    }

    /// New connects go to a fresh acceptor (a restarted host process).
    public func replaceAcceptor() -> LoopbackAcceptor {
        activeAcceptor.continuation.finish()
        activeAcceptor = LoopbackAcceptor()
        return activeAcceptor
    }

    public func setRefusing(_ kind: CarrierKind, _ refuse: Bool) {
        if refuse { refusing.insert(kind) } else { refusing.remove(kind) }
    }

    public func setConnectDelay(_ kind: CarrierKind, _ delay: Duration?) {
        connectDelays[kind] = delay
    }

    /// Later connects through `kind` produce `path`.
    public func setPath(_ kind: CarrierKind, _ path: PathKind?) {
        carrierPaths[kind] = path
    }

    public func connectCount(_ kind: CarrierKind) -> Int {
        connectCounts[kind] ?? 0
    }

    public var liveTransportCount: Int {
        get async {
            var count = 0
            for pipe in pipes where await !pipe.isClosed { count += 1 }
            return count
        }
    }

    /// Kills every live transport (both ends see `.closed(.pathLost)`).
    public func dropAll() async {
        let live = pipes
        pipes.removeAll()
        for pipe in live { await pipe.drop("dropped by test") }
    }

    /// Moves every live transport to `path` without dropping it.
    public func changePath(to path: PathKind) async {
        for pipe in pipes { await pipe.changePath(to: path) }
    }

    public func reportRTT(_ rtt: Duration) async {
        for pipe in pipes { await pipe.reportRTT(rtt) }
    }

    public func reportHealth(_ health: LinkHealth) async {
        for pipe in pipes { await pipe.reportHealth(health) }
    }

    /// A network change: live transports die, and every carrier produces
    /// `path` from now on.
    public func roam(to path: PathKind) async {
        for kind in Set(carrierPaths.keys).union(connectCounts.keys) { carrierPaths[kind] = path }
        roamPath = path
        await dropAll()
    }

    private var roamPath: PathKind?

    func connect(_ carrier: LoopbackCarrier) async throws -> LoopbackTransport {
        connectCounts[carrier.kind, default: 0] += 1
        if let delay = connectDelays[carrier.kind] {
            try await clock.sleep(for: delay)
        }
        try Task.checkCancellation()
        guard !refusing.contains(carrier.kind) else { throw LoopbackError.refused }
        let kind = carrierPaths[carrier.kind] ?? roamPath ?? carrier.defaultPath
        let path = LinkPath(kind: kind, carrier: carrier.kind)
        let dialerInbox = TransportInbox()
        let hostInbox = TransportInbox()
        let pipe = LoopbackPipe(
            path: path,
            inboxes: [dialerInbox, hostInbox],
            conditions: conditions,
            clock: clock,
            maxFrameBytes: carrier.capabilities.maxFrameBytes
        )
        pipes.append(pipe)
        let host = LoopbackTransport(pipe: pipe, side: 1, events: hostInbox.events, capabilities: carrier.capabilities)
        if case .dropped = activeAcceptor.continuation.yield(host) {
            await host.close()
            throw LoopbackError.refused
        }
        return LoopbackTransport(pipe: pipe, side: 0, events: dialerInbox.events, capabilities: carrier.capabilities)
    }
}
