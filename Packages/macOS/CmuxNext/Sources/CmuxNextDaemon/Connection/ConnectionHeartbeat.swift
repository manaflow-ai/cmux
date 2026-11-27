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
    /// The waits ``untilSilent(_:)`` ends at the next not-answering verdict, by id.
    private let silentWaits = Mutex<(next: UInt64, ends: [UInt64: @Sendable () -> Void])>((0, [:]))

    init(clock: any Clock<Duration> = ContinuousClock()) {
        // An ask may go up to 5 s early on a wake that already happened (``WakeCoalescer``): at idle the
        // heartbeat costs no wake of its own (0.07/s on cmux20-bench, 2026-11-25).
        timer = DemandTimer(owner: "DaemonConnection.heartbeat", clock: clock, early: .seconds(5))
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

    /// `work`'s value, or nil once this heartbeat finds the daemon not answering while it waits: its
    /// next verdict past the misses (`heartbeat` x `heartbeatMisses` of silence on `identify`, which
    /// the daemon answers before its connection's queue), so silence ends the wait and slowness never
    /// does. Only for a wait with no side effect (the sync barrier's `identify`): `work` goes on to
    /// its reply or the connection's end unwatched. With no heartbeat running it waits as `work` does.
    func untilSilent<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T? {
        let wait = SilentWait<T>()
        let id = silentWaits.withLock { waits -> UInt64 in
            waits.next &+= 1
            waits.ends[waits.next] = { wait.finish(.success(nil)) }
            return waits.next
        }
        defer { _ = silentWaits.withLock { $0.ends.removeValue(forKey: id) } }
        // task-owner: the request's own wait; ends with its reply or the connection's end
        Task {
            do { wait.finish(.success(try await work())) } catch { wait.finish(.failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { wait.store($0) }
        } onCancel: {
            wait.finish(.failure(CancellationError()))
        }
    }

    private func endSilentWaits() {
        let ends = silentWaits.withLock { waits in
            defer { waits.ends = [:] }
            return Array(waits.ends.values)
        }
        for end in ends { end() }
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
            if !step.answering { endSilentWaits() }
            schedule(transport, every: interval, misses: limit, run: run)
        default: // a later start or a stop ended the run
            return
        }
    }
}

/// One ``ConnectionHeartbeat/untilSilent(_:)`` wait: the first end (the work's, the silence's or the
/// caller's cancel) resumes it.
private final class SilentWait<T: Sendable>: Sendable {
    private enum State {
        case idle
        case waiting(CheckedContinuation<T?, any Error>)
        case ended(Result<T?, any Error>)
    }

    private let state = Mutex(State.idle)

    func store(_ continuation: CheckedContinuation<T?, any Error>) {
        let ended: Result<T?, any Error>? = state.withLock { state in
            if case .ended(let result) = state { return result }
            state = .waiting(continuation)
            return nil
        }
        if let ended { continuation.resume(with: ended) }
    }

    func finish(_ result: Result<T?, any Error>) {
        let waiting: CheckedContinuation<T?, any Error>? = state.withLock { state in
            switch state {
            case .ended:
                return nil
            case .waiting(let continuation):
                state = .ended(result)
                return continuation
            case .idle:
                state = .ended(result)
                return nil
            }
        }
        waiting?.resume(with: result)
    }
}
