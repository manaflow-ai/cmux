import CmuxNextWakeups
import Foundation
import Synchronization

/// The liveness of a bridged connection (a paired server's owner session
/// through `cmux link dial`, `DaemonEndpoint.bridge`). The overlay keeps a
/// silent peer for 10 minutes (a closed lid), so a lost server would hang
/// the connection: every interval the connection asks the daemon
/// `identify`, and `misses` unanswered asks in a row close the transport,
/// which reconnects and shows the server unreachable. The ask is a plain
/// daemon request on a `DemandTimer`: it counts as no user activity, takes
/// no power assertion and does not wake a sleeping Mac, so it never keeps a
/// laptop awake.
final class BridgeHeartbeat: Sendable {
    private let timer: DemandTimer
    /// Unanswered asks in a row and the run they belong to.
    private let state = Mutex((misses: 0, run: UInt64(0)))

    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "DaemonConnection.heartbeat", clock: clock)
    }

    /// Starts asking on `transport`; a later start (a reconnect) or `stop`
    /// ends the earlier run, and a closed transport ends it after its misses.
    func start(_ transport: LineTransport, every interval: Duration, misses limit: Int) {
        let run = state.withLock { state -> UInt64 in
            state = (0, state.run &+ 1)
            return state.run
        }
        schedule(transport, every: interval, misses: limit, run: run)
    }

    func stop() {
        state.withLock { $0.run &+= 1 }
        timer.cancel()
    }

    private func schedule(_ transport: LineTransport, every interval: Duration, misses limit: Int, run: UInt64) {
        timer.schedule(after: interval) { [weak self] in
            await self?.tick(transport, every: interval, misses: limit, run: run)
        }
    }

    private func tick(_ transport: LineTransport, every interval: Duration, misses limit: Int, run: UInt64) async {
        let answered = (try? await transport.request(cmd: IdentifyRequest.command, timeout: interval) { id in
            try WireCoding.encodeRequest(IdentifyRequest(), id: id)
        }) != nil
        let close = state.withLock { state -> Bool? in
            guard state.run == run else { return nil }
            state.misses = answered ? 0 : state.misses + 1
            return state.misses >= limit
        }
        guard let close else { return }
        if close {
            transport.close()
        } else {
            schedule(transport, every: interval, misses: limit, run: run)
        }
    }
}
