public import CmuxLink
import os

/// Test hooks over every live connection of a carrier and acceptor pair
/// (the conformance harness). Not for production use.
@_spi(Testing)
public final class WebRTCFaultInjector: Sendable {
    private struct State {
        var live: [ObjectIdentifier: WebRTCConnection] = [:]
        var rate: Int?
        var pathOverride: PathKind?
    }

    // carve-out: test hook registry, read synchronously at connection init.
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    var currentRate: Int? { state.withLock { $0.rate } }
    var currentPathOverride: PathKind? { state.withLock { $0.pathOverride } }

    func register(_ connection: WebRTCConnection) {
        state.withLock { $0.live[ObjectIdentifier(connection)] = connection }
    }

    func unregister(_ connection: WebRTCConnection) {
        _ = state.withLock { $0.live.removeValue(forKey: ObjectIdentifier(connection)) }
    }

    public var liveCount: Int { state.withLock { $0.live.count } }

    /// Kills every live peer connection with no close handshake; both ends
    /// see `.pathLost` (the far end through SCTP abort).
    public func dropAll() async {
        let connections = state.withLock { Array($0.live.values) }
        for connection in connections { await connection.abort() }
    }

    /// Ends every live peer connection and tells each peer with `bye` (the
    /// peer is gone: datagram channels see `reset` on both ends).
    public func resetAll() async {
        let connections = state.withLock { Array($0.live.values) }
        for connection in connections { await connection.abort(sendBye: true) }
    }

    /// Moves live transports to `kind` without dropping them (what the
    /// selected-pair callback reports after ICE moves to or from TURN).
    public func changePath(to kind: PathKind) async {
        let connections = state.withLock { Array($0.live.values) }
        for connection in connections { await connection.forcePath(kind) }
    }

    /// Drops live transports; new ones report `kind`.
    public func roam(to kind: PathKind) async {
        state.withLock { $0.pathOverride = kind }
        await dropAll()
    }

    /// Limits every transport's send rate (`nil` removes the limit).
    public func throttle(bytesPerSecond: Int?) {
        let connections = state.withLock { state -> [WebRTCConnection] in
            state.rate = bytesPerSecond
            return Array(state.live.values)
        }
        for connection in connections { connection.pacer.setRate(bytesPerSecond) }
    }
}
