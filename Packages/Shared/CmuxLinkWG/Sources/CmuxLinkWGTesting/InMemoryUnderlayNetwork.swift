public import CmuxLink
public import CmuxLinkWG
import Foundation

/// An in-process stand-in for B2's WebRTC stack: `open` makes a new pair of
/// underlays (one simulated peer connection) and hands the host end to the
/// listener. Fault hooks change the ICE path, roam (paths die, the next
/// open lands on a new path) and reset (the peer is gone).
public final class InMemoryUnderlayNetwork: DatagramUnderlayDialer, DatagramUnderlayListener {
    public let incoming: AsyncStream<any DatagramUnderlay>
    private let core: Core

    public init(conditions: UnderlayConditions = .perfect, path: PathKind = .p2p, clock: LinkClock = .continuous) {
        let (stream, sink) = AsyncStream.makeStream(of: (any DatagramUnderlay).self, bufferingPolicy: .unbounded)
        incoming = stream
        core = Core(conditions: conditions, path: path, clock: clock, listener: sink)
    }

    public func open(to peer: LinkPeer) async throws -> any DatagramUnderlay {
        try await core.open()
    }

    /// Every live link moves to `kind` without dropping.
    public func changePath(to kind: PathKind) async {
        await core.changePath(to: kind)
    }

    /// Live links die with `.pathLost`; the next open lands on `kind`.
    public func roam(to kind: PathKind) async {
        await core.roam(to: kind)
    }

    /// Live links end with `.reset` on both sides (peer gone).
    public func reset() async {
        await core.reset()
    }

    public func setConditions(_ conditions: UnderlayConditions) async {
        await core.setConditions(conditions)
    }

    /// While set, `open` fails.
    public func refuseOpens(_ refuse: Bool) async {
        await core.setRefusing(refuse)
    }

    /// Underlays opened so far.
    public var openCount: Int {
        get async { await core.openCount }
    }

    public var conditions: UnderlayConditions {
        get async { await core.conditions }
    }

    private actor Core {
        private(set) var conditions: UnderlayConditions
        private var path: PathKind
        private let clock: LinkClock
        private let listener: AsyncStream<any DatagramUnderlay>.Continuation
        private var links: [InMemoryUnderlayLink] = []
        private var refusing = false
        private(set) var openCount = 0

        init(conditions: UnderlayConditions, path: PathKind, clock: LinkClock, listener: AsyncStream<any DatagramUnderlay>.Continuation) {
            self.conditions = conditions
            self.path = path
            self.clock = clock
            self.listener = listener
        }

        func open() throws -> any DatagramUnderlay {
            guard !refusing else { throw InMemoryUnderlayError.refused }
            openCount += 1
            let (dialerEvents, dialerSink) = AsyncStream.makeStream(of: UnderlayEvent.self, bufferingPolicy: .unbounded)
            let (hostEvents, hostSink) = AsyncStream.makeStream(of: UnderlayEvent.self, bufferingPolicy: .unbounded)
            let link = InMemoryUnderlayLink(
                path: path, conditions: conditions,
                seed: conditions.seed &+ UInt64(openCount) &* 0x9E37_79B9,
                clock: clock, sinks: [dialerSink, hostSink]
            )
            links.append(link)
            let max = conditions.maxDatagramBytes
            listener.yield(InMemoryUnderlay(events: hostEvents, maxDatagramBytes: max, link: link, side: .host))
            return InMemoryUnderlay(events: dialerEvents, maxDatagramBytes: max, link: link, side: .dialer)
        }

        func changePath(to kind: PathKind) async {
            path = kind
            for link in links { await link.changePath(to: kind) }
        }

        func roam(to kind: PathKind) async {
            path = kind
            let dying = links
            links.removeAll()
            for link in dying { await link.end(dialer: .pathLost("roam"), host: .pathLost("roam")) }
        }

        func reset() async {
            let dying = links
            links.removeAll()
            for link in dying { await link.end(dialer: .reset, host: .reset) }
        }

        func setConditions(_ conditions: UnderlayConditions) async {
            self.conditions = conditions
            for link in links { await link.setConditions(conditions) }
        }

        func setRefusing(_ refusing: Bool) {
            self.refusing = refusing
        }
    }
}
