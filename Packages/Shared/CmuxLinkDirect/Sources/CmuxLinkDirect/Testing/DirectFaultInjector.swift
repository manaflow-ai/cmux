public import CmuxLink
import os

/// Test hooks over every live transport of a carrier and acceptor pair
/// (the conformance harness). Not for production use.
@_spi(Testing)
public final class DirectFaultInjector: Sendable {
    final class Registration: Sendable {}

    private struct State {
        var live: [ObjectIdentifier: DirectTransportCore] = [:]
        var rate: Int?
        var pathKind: PathKind = .direct
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    var currentRate: Int? { state.withLock { $0.rate } }

    /// The path kind new transports report (the roam hook).
    var currentPathKind: PathKind { state.withLock { $0.pathKind } }

    func register(_ core: DirectTransportCore, as registration: Registration) {
        state.withLock { $0.live[ObjectIdentifier(registration)] = core }
    }

    func unregister(_ registration: Registration) {
        _ = state.withLock { $0.live.removeValue(forKey: ObjectIdentifier(registration)) }
    }

    public var liveCount: Int { state.withLock { $0.live.count } }

    /// Kills every live socket (both ends see `.pathLost`).
    public func dropAll() {
        let cores = state.withLock { Array($0.live.values) }
        for core in cores { core.socket.cancel() }
    }

    /// Moves live transports to `kind` without dropping them.
    public func changePath(to kind: PathKind) {
        let cores = state.withLock { Array($0.live.values) }
        for core in cores { core.movePath(to: LinkPath(kind: kind, carrier: core.path.carrier)) }
    }

    /// Drops live transports; reconnects report `kind`.
    public func roam(to kind: PathKind) {
        state.withLock { $0.pathKind = kind }
        dropAll()
    }

    /// Limits every writer's send rate (`nil` removes the limit).
    public func throttle(bytesPerSecond: Int?) async {
        let cores = state.withLock { state -> [DirectTransportCore] in
            state.rate = bytesPerSecond
            return Array(state.live.values)
        }
        for core in cores { await core.writer.setRate(bytesPerSecond) }
    }
}
