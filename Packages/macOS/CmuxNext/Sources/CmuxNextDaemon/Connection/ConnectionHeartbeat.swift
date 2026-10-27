public import CmuxNextWakeups
import CmuxNextTrace
import Foundation
import CmuxNextCompat

/// The liveness of a connection. A daemon that stops answering keeps its
/// socket open (an owner stopped with SIGSTOP or wedged in its main loop;
/// over a bridge, a lost server the overlay keeps for 10 minutes for a
/// closed lid), so no EOF ever ends the connection and the app kept showing
/// it connected (cx-jniyz.4). Every interval the connection asks the daemon
/// `identify`, and `misses` unanswered asks in a row close the transport,
/// which emits `.disconnected` (the not-connected state) and reconnects once
/// the daemon answers again. The ask is a plain daemon request on a
/// `DemandTimer`: it counts as no user activity, takes no power assertion and
/// does not wake a sleeping Mac, so it never keeps a laptop awake.
///
/// With the app's Energy Saver policy (``follow(_:)``, p14-energy-120) it asks nothing while the
/// Mac or its displays sleep, and a wake drops the ask in flight: its timeout ran through the sleep,
/// so it would count a miss the daemon never had. Once a wake finds the network it asks once after
/// ``KeepaliveGate/reconnectDelay()``, so a bridge that died in the sleep closes within its misses.
/// Chrome's GCM heartbeat stops on `OnSuspend` and checks the connection on `OnResume` the same way
/// (google_apis/gcm/engine/heartbeat_manager.cc).
///
/// Each ask also reads the daemon's trace clock (`identify {trace_clock: true}`, p09-observability-116), so a
/// daemon on another machine has a clock offset for its trace recording with no extra request: the shortest
/// round trip of the last eight answers gives ``clockOffset()`` (``DaemonClockFilter``). A sleep forgets them,
/// since this Mac's trace clock stops while the remote one keeps counting.
public final class ConnectionHeartbeat: Sendable {
    /// What one ask got back.
    enum Answer: Sendable, Equatable {
        /// No answer within the timeout.
        case missed
        /// An answer, with its clock exchange when the daemon read its clock.
        case answered(DaemonClockSample?)
    }

    /// One run's daemon: how to ask it and how to close it.
    struct Probe: Sendable {
        /// Asks `identify` with this timeout.
        let ask: @Sendable (_ timeout: Duration) async -> Answer
        /// Closes the transport (`.disconnected`, then a reconnect).
        let close: @Sendable () -> Void
        let interval: Duration
        let misses: Int
    }

    private struct State {
        var misses = 0
        /// Bumped by every start, stop and pause: an ask of an older run changes nothing.
        var run: UInt64 = 0
        /// The current run's daemon; nil when stopped.
        var probe: Probe?
        var gate: KeepaliveGate?
        /// The current run's clock exchanges.
        var clock = DaemonClockFilter()
    }

    /// The two `identify` fields an ask reads; a daemon without `trace-fetch-v1` sends neither.
    struct TraceClockReading: Decodable, Sendable {
        let nanos: UInt64?
        let domain: String?

        enum CodingKeys: String, CodingKey {
            case nanos = "trace_clock_ns", domain = "trace_clock_domain"
        }

        /// The exchange that carried this reading, or nil when the daemon read no clock.
        func sample(sentNanos: UInt64, receivedNanos: UInt64) -> DaemonClockSample? {
            guard let nanos, let domain else { return nil }
            return DaemonClockSample(sentNanos: sentNanos, remoteNanos: nanos, receivedNanos: receivedNanos, remoteDomain: domain)
        }
    }

    private let timer: DemandTimer
    private let traceClock: TraceClock
    // concurrency-allow: the run's counters, its probe, gate and clock exchanges (eight samples), read and written synchronously by the timer's ask and the policy's edges (lock carve-out: a few fields, no I/O; the timer is scheduled with no wait under it).
    private let state = Mutex(State())

    init(clock: any Clock<Duration> = ContinuousClock(), traceClock: TraceClock = TraceClock()) {
        timer = DemandTimer(owner: "DaemonConnection.heartbeat", clock: clock)
        self.traceClock = traceClock
    }

    /// The current daemon's trace clock against this Mac's, from the shortest exchange of the last eight asks;
    /// nil before the first answer that read a clock (an older daemon never sends one), after a sleep and while stopped.
    public func clockOffset() -> DaemonClockOffset? {
        state.withLock { $0.clock.estimate }
    }

    /// Follows `gate`'s sleep and wake from now on, for this connection and its reconnects, in place
    /// of an earlier gate. The daemon service hands each connection a gate on the app's one policy
    /// source (`MainWorkScheduler.energy`) once it has the connection; until then it asks on its interval.
    public func follow(_ gate: KeepaliveGate) {
        let old = state.withLock { state -> KeepaliveGate? in
            defer { state.gate = gate }
            return state.gate
        }
        old?.stop()
        gate.follow { [weak self] edge in self?.changed(edge) }
        if gate.isPaused { pause() }
    }

    /// Starts asking on `transport`; a later start (a reconnect) or `stop`
    /// ends the earlier run, and a closed transport ends it after its misses.
    func start(_ transport: LineTransport, every interval: Duration, misses limit: Int) {
        let traceClock = traceClock
        start(Probe(ask: { timeout in
            let sent = traceClock.nowNanos()
            guard let response = try? await transport.request(cmd: IdentifyRequest.commandName, timeout: timeout, { id in
                try WireCoding.encodeRequest(IdentifyRequest(traceClock: true), id: id)
            }) else { return .missed }
            let received = traceClock.nowNanos()
            let reading = try? WireCoding.decodeResponse(TraceClockReading.self, from: response)
            return .answered(reading?.sample(sentNanos: sent, receivedNanos: received))
        }, close: { transport.close() }, interval: interval, misses: limit))
    }

    /// Starts asking `probe`; ``start(_:every:misses:)`` with the transport left out (tests).
    func start(_ probe: Probe) {
        let run = state.withLock { state -> UInt64 in
            state.misses = 0
            state.run &+= 1
            state.probe = probe
            state.clock.reset()
            return state.run
        }
        schedule(after: probe.interval, run: run)
    }

    func stop() {
        state.withLock { state in
            state.run &+= 1
            state.probe = nil
            state.clock.reset()
        }
        timer.cancel()
    }

    /// Arms the next ask of run `run` after `delay`, unless the gate holds the keepalive or a later
    /// start, stop or pause took over.
    private func schedule(after delay: Duration, run: UInt64) {
        let gate = state.withLock { $0.gate }
        let arm = {
            guard self.state.withLock({ $0.run == run && $0.probe != nil }) else { return }
            self.timer.schedule(after: delay) { [weak self] in await self?.tick(run: run) }
        }
        if let gate { gate.whileAwake(arm) } else { arm() }
    }

    private func tick(run: UInt64) async {
        guard let probe = state.withLock({ $0.run == run ? $0.probe : nil }) else { return }
        let answer = await probe.ask(probe.interval)
        let close = state.withLock { state -> Bool? in
            guard state.run == run else { return nil }
            switch answer {
            case .missed:
                state.misses += 1
            case .answered(let sample):
                state.misses = 0
                if let sample { state.clock.add(sample) }
            }
            return state.misses >= probe.misses
        }
        guard let close else { return }
        if close {
            probe.close()
        } else {
            schedule(after: probe.interval, run: run)
        }
    }

    private func changed(_ edge: KeepaliveGate.Edge) {
        switch edge {
        case .pause:
            pause()
        case .resume:
            if case let (run, interval)? = resumeRun() { schedule(after: interval, run: run) }
        case .reconnect:
            let delay = state.withLock { $0.gate?.reconnectDelay() }
            if let delay, case let (run, _)? = resumeRun() { schedule(after: delay, run: run) }
        }
    }

    /// Drops the armed ask and the one in flight, so nothing asks and no miss counts while asleep. The clock
    /// exchanges go too: this Mac's trace clock stops in the sleep, a remote machine's does not.
    private func pause() {
        state.withLock { state in
            state.run &+= 1
            state.clock.reset()
        }
        timer.cancel()
    }

    /// A new run of the current probe with no misses, after a pause; nil when stopped.
    private func resumeRun() -> (run: UInt64, interval: Duration)? {
        state.withLock { state in
            guard let probe = state.probe else { return nil }
            state.run &+= 1
            state.misses = 0
            return (state.run, probe.interval)
        }
    }
}
