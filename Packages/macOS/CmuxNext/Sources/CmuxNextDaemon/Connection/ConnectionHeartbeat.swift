internal import CCmuxDaemonConnFFI
import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// The liveness of a connection. A daemon that stops answering keeps its
/// socket open (an owner stopped with SIGSTOP or wedged in its main loop;
/// over a bridge, a lost server the overlay keeps for 10 minutes for a
/// closed lid), so no EOF ever ends the connection (cx-jniyz.4). Every
/// interval the connection asks the daemon `identify`; `misses` unanswered
/// asks in a row mark the daemon not answering (``answering``), and the next
/// answer clears it. The ask is a plain daemon request on a `DemandTimer`: it
/// counts as no user activity, takes no power assertion and does not wake a
/// sleeping Mac, so it never keeps a laptop awake.
///
/// No client clock ends a live daemon's connection (P0 2026-10-30, v2.2.10-opt:
/// under swap the asks went unanswered, the close failed every create, window
/// save and trail step on the connection with "closed by client"). A local
/// connection whose daemon process is alive (``LineTransport/peerProcessIsAlive``)
/// stays open and keeps its pending requests, which get their replies when the
/// daemon answers; only EOF, a socket error or the process's exit end it. A
/// bridged connection, whose daemon this Mac cannot see, still closes after its
/// misses, which emits `.disconnected` and reconnects.
///
/// The counting is Rust's (`cmux_heartbeat_*`, cmux-daemon-conn-core src/heartbeat.rs); the timer, the ask
/// and the observer stay here.
final class ConnectionHeartbeat: Sendable {
    private let timer: DemandTimer
    /// Unanswered asks in a row, the run they belong to and ``answering`` (`CmuxHeartbeat`).
    private let state = Mutex(cmux_heartbeat_new())
    /// Told each change of ``answering``, outside the lock (``observeAnswering(_:)``).
    private let observer = Mutex<(@Sendable (Bool) -> Void)?>(nil)

    init(clock: any Clock<Duration> = ContinuousClock()) {
        timer = DemandTimer(owner: "DaemonConnection.heartbeat", clock: clock)
    }

    /// False while the daemon left `misses` asks in a row unanswered and its connection stays open
    /// (its process is alive); true again at its next answer, a new start or a stop.
    var answering: Bool { state.withLock { $0.answering } }

    /// Calls `observer` on the heartbeat's timer task: with true when the daemon answers again, and with false
    /// at each unanswered ask past the misses while its connection stays open (one per interval), so the owner
    /// can probe it then (``DaemonRecovery`` runs one `server ensure` per call); nil stops. The value is a hint
    /// of the moment: read ``answering`` for the current one.
    func observeAnswering(_ observer: (@Sendable (Bool) -> Void)?) {
        self.observer.store(observer)
    }

    private func tell(_ answering: Bool) {
        if let observer = observer.load() { observer(answering) }
    }

    /// Starts asking on `transport`; a later start (a reconnect) or `stop`
    /// ends the earlier run, and a closed transport ends it after its misses.
    func start(_ transport: LineTransport, every interval: Duration, misses limit: Int) {
        let (run, told) = state.withLock { beat -> (UInt64, Bool) in
            var told = false
            let run = cmux_heartbeat_start(&beat, &told)
            return (run, told)
        }
        if told { tell(true) }
        schedule(transport, every: interval, misses: limit, run: run)
    }

    func stop() {
        let told = state.withLock { cmux_heartbeat_stop(&$0) }
        timer.cancel()
        if told { tell(true) }
    }

    private func schedule(_ transport: LineTransport, every interval: Duration, misses limit: Int, run: UInt64) {
        timer.schedule(after: interval) { [weak self] in
            await self?.tick(transport, every: interval, misses: limit, run: run)
        }
    }

    private func tick(_ transport: LineTransport, every interval: Duration, misses limit: Int, run: UInt64) async {
        guard !transport.isClosed else { return }
        let answered = (try? await transport.request(cmd: IdentifyRequest.command, timeout: interval) { id in
            try WireCoding.encodeRequest(IdentifyRequest(), id: id)
        }) != nil
        let peerAlive = transport.peerProcessIsAlive
        let step = state.withLock { cmux_heartbeat_tick(&$0, run, answered, Int64(clamping: limit), peerAlive) }
        switch step.action {
        case 1: // missed, and its daemon is not alive
            transport.close()
        case 2:
            if step.tell { tell(step.answering) }
            schedule(transport, every: interval, misses: limit, run: run)
        default: // a later start or a stop ended the run
            return
        }
    }
}
