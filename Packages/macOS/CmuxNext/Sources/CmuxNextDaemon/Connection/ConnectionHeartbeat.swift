public import CmuxNextWakeups
import Foundation
import CmuxNextCompat

/// The liveness of a connection. A daemon that stops answering keeps its
/// socket open (an owner stopped with SIGSTOP or wedged in its main loop;
/// over a bridge, a lost server the overlay keeps for 10 minutes for a
/// closed lid), so no EOF ever ends the connection and the app kept showing
/// it connected (cx-jniyz.4). After `interval` with nothing from the daemon
/// the connection asks it `identify`, and `misses` unanswered asks in a row,
/// with nothing from the daemon between them, close the transport, which
/// emits `.disconnected` (the not-connected state) and reconnects once the
/// daemon answers again. The ask is a plain daemon
/// request on a `DemandTimer`: it counts as no user activity, takes no power
/// assertion and does not wake a sleeping Mac, so it never keeps a laptop awake.
///
/// Silence decides, not a period: any frame from the daemon proves it alive, so a
/// connection with traffic never asks, and the deadline is read lazily at its fire rather than moved
/// per frame. QUIC sends its keepalive PING the same way, only after `ping_timeout` (15 s) with no
/// packet (quiche/quic/core/quic_ping_manager.cc). What a person sees decides the silence
/// (``ConnectionPresence``, injected by the App): `interval` while a window shows or a request
/// waits; while hidden, `hiddenInterval` for a connection with a notification stream (a bridge: a
/// lost server over a closed lid must still be found) and no ask at all for the others. A window
/// showing again or the app's activation asks once.
///
/// With the app's Energy Saver policy (a ``KeepaliveGate`` it follows) it asks nothing
/// while the Mac or its displays sleep, and a wake drops the ask in flight: its timeout ran through the
/// sleep, so it would count a miss the daemon never had. Once a wake finds the network it asks once
/// after ``KeepaliveGate/reconnectDelay()``, so a bridge that died in the sleep closes within its
/// misses. Chrome's GCM heartbeat stops on `OnSuspend` and checks the connection on `OnResume` the
/// same way (google_apis/gcm/engine/heartbeat_manager.cc).
public final class ConnectionHeartbeat: Sendable {
    /// One run's daemon: how to ask it, how to close it, and how long it has been quiet.
    struct Probe: Sendable {
        /// Asks `identify` with this timeout; true when it answered.
        let ask: @Sendable (_ timeout: Duration) async -> Bool
        /// Closes the transport (`.disconnected`, then a reconnect).
        let close: @Sendable () -> Void
        /// How long since the daemon last sent anything (``LineTransport/inboundSilence``).
        let silence: @Sendable () -> Duration
        /// The silence that asks while a window shows or a request waits, and each ask's timeout.
        let interval: Duration
        /// The silence that asks while hidden and idle; nil asks nothing then.
        let hiddenInterval: Duration?
        let misses: Int

        /// - Parameter silence: By default the daemon was never heard: the run's own start and
        ///   answers bound the silence alone.
        init(ask: @escaping @Sendable (_ timeout: Duration) async -> Bool, close: @escaping @Sendable () -> Void,
             silence: @escaping @Sendable () -> Duration = { .seconds(Int64.max) },
             interval: Duration, hiddenInterval: Duration? = nil, misses: Int) {
            self.ask = ask
            self.close = close
            self.silence = silence
            self.interval = interval
            self.hiddenInterval = hiddenInterval
            self.misses = misses
        }
    }

    private struct State {
        /// Unanswered asks with nothing heard from the daemon since: a frame after a miss ends the run of misses.
        var misses = 0
        /// When the last ask missed, on `elapsed`.
        var missedAt: Duration = .zero
        /// Bumped by every start, stop and pause: an ask of an older run changes nothing.
        var run: UInt64 = 0
        /// The current run's daemon; nil when stopped.
        var probe: Probe?
        var gate: KeepaliveGate?
        var presence: ConnectionPresenceObservation?
        /// A window shows (true with no ``ConnectionPresence``).
        var shown = true
        /// A request on the connection waits for its reply.
        var busy = false
        /// The current run's ask is out: no second ask, no arm until it ends.
        var asking = false
        /// When the run started, the daemon last answered an ask, or a request went out while hidden, on
        /// `elapsed`: the silence is at most the time since.
        var heard: Duration = .zero

        /// The silence that asks now; nil asks nothing.
        var cadence: Duration? {
            guard let probe else { return nil }
            return shown || busy ? probe.interval : probe.hiddenInterval
        }
    }

    /// What one arm does.
    private enum Arm {
        /// Ask after this delay, whatever the silence (a wake, a show, an activation).
        case askAfter(Duration)
        /// Fire when the silence reaches the cadence.
        case onSilence

        var isForced: Bool {
            switch self {
            case .askAfter: true
            case .onSilence: false
            }
        }
    }

    private let timer: DemandTimer
    /// Time since the heartbeat was made, on the clock its timer sleeps on.
    private let elapsed: @Sendable () -> Duration
    // concurrency-allow: the run's counters, its probe, gate and presence, read and written synchronously by the timer's ask and the policy's and presence's edges (lock carve-out: a few fields, no I/O; the timer is scheduled with no wait under it).
    private let state = Mutex(State())

    init(clock: any Clock<Duration> = ContinuousClock()) {
        // timer-class-allow: off main: each ask runs on the connection's own probe (a request on its transport) and posts no main-thread job
        timer = DemandTimer(owner: "DaemonConnection.heartbeat", clock: clock)
        elapsed = LineTransport.elapsedReader(clock)
    }

    /// Follows `gate`'s sleep and wake from now on, for this connection and its reconnects, in place
    /// of an earlier gate. The daemon service hands each connection a gate on the app's one policy
    /// source (`MainWorkScheduler.energy`) once it has the connection; until then it asks on silence.
    public func follow(_ gate: KeepaliveGate) {
        let old = state.withLock { state -> KeepaliveGate? in
            defer { state.gate = gate }
            return state.gate
        }
        old?.stop()
        gate.follow { [weak self] edge in self?.changed(edge) }
        if gate.isPaused { pause() }
    }

    /// Follows what a person sees from now on, for this connection and its reconnects, in place of
    /// an earlier presence. The daemon service hands each connection the App's one presence.
    public func follow(_ presence: ConnectionPresence) {
        let observation = presence.observe { [weak self] edge in self?.changed(edge) }
        let shown = presence.isShown
        let (old, run) = state.withLock { state -> (ConnectionPresenceObservation?, UInt64?) in
            defer { state.presence = observation }
            state.shown = shown
            return (state.presence, state.probe == nil ? nil : state.run)
        }
        old?.cancel()
        if let run { schedule(.onSilence, run: run) }
    }

    /// Whether a request on the connection waits for its reply (its count left or reached 0). While
    /// hidden it asks on `interval`, so a request to a wedged daemon is found as when shown.
    func requestsWaiting(_ waiting: Bool) {
        requestsWaiting { waiting }
    }

    /// `requestsWaiting(_:)` reading `waiting` under the heartbeat's lock, so that edges told out of
    /// order (two threads' requests) still leave the latest answer.
    func requestsWaiting(_ waiting: () -> Bool) {
        let now = elapsed()
        let run = state.withLock { state -> UInt64? in
            let before = state.cadence
            let busy = waiting()
            state.busy = busy
            guard state.probe != nil, state.cadence != before else { return nil }
            // The request's own reply proves the daemon alive: the silence counts from its send.
            if busy { state.heard = max(state.heard, now) }
            return state.run
        }
        if let run { schedule(.onSilence, run: run) }
    }

    /// Starts asking on `transport`; a later start (a reconnect) or `stop`
    /// ends the earlier run, and a closed transport ends it after its misses.
    func start(_ transport: LineTransport, every interval: Duration, hidden hiddenInterval: Duration?, misses limit: Int) {
        start(Probe(ask: { timeout in
            (try? await transport.request(cmd: IdentifyRequest.commandName, timeout: timeout) { id in
                try WireCoding.encodeRequest(IdentifyRequest(), id: id)
            }) != nil
        }, close: { transport.close() }, silence: { transport.inboundSilence },
        interval: interval, hiddenInterval: hiddenInterval, misses: limit))
    }

    /// Starts asking `probe`; ``start(_:every:hidden:misses:)`` with the transport left out (tests).
    func start(_ probe: Probe) {
        let now = elapsed()
        let run = state.withLock { state -> UInt64 in
            state.misses = 0
            state.run &+= 1
            state.probe = probe
            state.asking = false
            state.heard = now
            return state.run
        }
        schedule(.onSilence, run: run)
    }

    func stop() {
        state.withLock { state in
            state.run &+= 1
            state.probe = nil
            state.asking = false
        }
        timer.cancel()
    }

    /// Arms the next fire of run `run`, unless the gate holds the keepalive, a later start, stop or
    /// pause took over, or an ask is out. With no cadence it drops the armed fire instead.
    private func schedule(_ arm: Arm, run: UInt64) {
        let gate = state.withLock { $0.gate }
        let apply = {
            let delay = self.state.withLock { state -> Duration?? in
                guard state.run == run, let probe = state.probe, !state.asking else { return nil }
                switch arm {
                case .askAfter(let delay):
                    return .some(delay)
                case .onSilence:
                    guard let cadence = state.cadence else { return .some(nil) }
                    return .some(max(cadence - self.silence(state, probe), .zero))
                }
            }
            switch delay {
            case nil: return
            case .some(nil): self.timer.cancel()
            case .some(let delay?):
                let forced = arm.isForced
                self.timer.schedule(after: delay) { [weak self] in await self?.tick(run: run, forced: forced) }
            }
        }
        if let gate { gate.whileAwake(apply) } else { apply() }
    }

    /// The silence now: the daemon's, bounded by the time since the run started or it last answered.
    private func silence(_ state: State, _ probe: Probe) -> Duration {
        min(probe.silence(), elapsed() - state.heard)
    }

    /// Asks when `forced` or the silence reached the cadence; otherwise arms for the rest of it.
    private func tick(run: UInt64, forced: Bool) async {
        enum Step {
            case ask(Probe)
            case wait
        }
        let step = state.withLock { state -> Step? in
            guard state.run == run, let probe = state.probe, !state.asking else { return nil }
            if state.misses > 0, probe.silence() < elapsed() - state.missedAt { state.misses = 0 }
            if !forced {
                guard let cadence = state.cadence else { return nil }
                if silence(state, probe) < cadence { return .wait }
            }
            state.asking = true
            return .ask(probe)
        }
        guard case .ask(let probe)? = step else {
            if case .wait? = step { schedule(.onSilence, run: run) }
            return
        }
        let answered = await probe.ask(probe.interval)
        let now = elapsed()
        let close = state.withLock { state -> Bool? in
            guard state.run == run else { return nil }
            state.asking = false
            state.misses = answered ? 0 : state.misses + 1
            if answered { state.heard = now } else { state.missedAt = now }
            return state.misses >= probe.misses
        }
        guard let close else { return }
        if close {
            probe.close()
        } else {
            // After a miss the silence is past the cadence already: the next ask goes at once.
            schedule(.onSilence, run: run)
        }
    }

    private func changed(_ edge: KeepaliveGate.Edge) {
        switch edge {
        case .pause:
            pause()
        case .resume:
            if let run = resumeRun() { schedule(.onSilence, run: run) }
        case .reconnect:
            let delay = state.withLock { $0.gate?.reconnectDelay() }
            if let delay, let run = resumeRun() { schedule(.askAfter(delay), run: run) }
        }
    }

    /// The app became active: one ask now, whatever the silence. The daemon service calls it on
    /// each activation while the App injects a ``ConnectionPresence``.
    public func activated() {
        if let run = state.withLock({ $0.probe == nil ? nil : $0.run }) { schedule(.askAfter(.zero), run: run) }
    }

    private func changed(_ edge: ConnectionPresence.Edge) {
        let run = state.withLock { state -> UInt64? in
            state.shown = edge == .shown
            return state.probe == nil ? nil : state.run
        }
        guard let run else { return }
        schedule(edge == .shown ? .askAfter(.zero) : .onSilence, run: run)
    }

    /// Drops the armed ask and the one in flight, so nothing asks and no miss counts while asleep.
    private func pause() {
        state.withLock { state in
            state.run &+= 1
            state.asking = false
        }
        timer.cancel()
    }

    /// A new run of the current probe with no misses, after a pause; nil when stopped.
    private func resumeRun() -> UInt64? {
        let now = elapsed()
        return state.withLock { state in
            guard state.probe != nil else { return nil }
            state.run &+= 1
            state.misses = 0
            state.asking = false
            state.heard = now
            return state.run
        }
    }
}
