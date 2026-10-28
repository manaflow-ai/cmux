import os
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups

extension MainThreadWatchdog {
    /// Writes one file per hang episode (``HangEpisodeRecorder``): the main thread's stack at
    /// the hang threshold, finalized with the duration once the main thread answers again.
    /// Nil (the default) writes nothing.
    public var episodes: HangEpisodeRecorder? {
        get { episodeSink.withLock { $0 } }
        set { episodeSink.withLock { $0 = newValue } }
    }

    /// One hang episode's report to ``onHangEpisode``, from the episode tracker
    /// (``HangEpisodeTracker``): it began, reached a checkpoint, or ended.
    public enum HangEpisodeEvent: Sendable {
        /// Still blocked: at the hang threshold, then at each doubling checkpoint (4 s, 8 s,
        /// 16 s, ...), with the stacks sampled now. `previous` is the duration of this episode's
        /// previous report to the sink; nil for its first.
        case blocked(Hang, previous: Duration?)
        /// The main thread answered again (or the watchdog stopped): the exact length, and this
        /// episode's last ``blocked(_:previous:)`` report to the sink (nil when it got none).
        case ended(duration: Duration, lastReport: Hang?)
    }

    /// Receives every hang episode's reports on the watchdog thread (the app's Sentry app
    /// hangs), not limited by `hangReportInterval`. A checkpoint report samples the main thread
    /// and every other thread while the main thread is still blocked; one that finds the main
    /// thread running again is not sent (its end follows). It must not wait for the main thread.
    public var onHangEpisode: (@Sendable (HangEpisodeEvent) -> Void)? {
        get { hangEpisodeSink.withLock { $0 } }
        set { hangEpisodeSink.withLock { $0 = newValue } }
    }

    /// The watchdog thread's hang bookkeeping (`watch(sampler:)`).
    struct HangState {
        var episodes: HangEpisodeTracker
        var assertedBeat: UInt64 = .max
        var lastReportNanos: UInt64?
        /// The open episode's last report to ``onHangEpisode``.
        var episodeReport: Hang?
    }

    /// Closes the open episode once the main thread moved past its beat or its run loop
    /// sleeps. A few atomic loads, and nothing when no episode is open. Watchdog thread only.
    func closeRecoveredEpisode(_ state: inout HangState) {
        guard state.episodes.openBeat != nil else { return }
        let beat = beatSequence.load(ordering: .acquiring)
        for event in state.episodes.observe(beat: beat, busy: !mainAsleep.load(ordering: .acquiring), elapsedNanos: 0) {
            handle(event, sampler: nil, state: &state)
        }
    }

    /// A stall just crossed the hang threshold (once per stall): samples the main thread and
    /// every other thread, opens the hang file, hands the hang to ``fatalHangs`` (every one),
    /// reports the episode (``onHangEpisode``, every one), and reports the hang (``onHang``) at
    /// most once per `hangReportInterval`. Watchdog thread only.
    func reportHang(beat: UInt64, elapsedNanos: UInt64, now: UInt64, sampler: ThreadStackSampler?, crashKeys: CrashKeySlots?,
                    trace: TraceRuntime?, state: inout HangState) {
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
        logger.fault("main thread hang: busy \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting")
        let due = state.lastReportNanos.map { now >= $0 &+ hangIntervalNanos } ?? true
        let sink = due ? onHang : nil
        let recorder = episodes
        let fatal = fatalHangs
        let episodeSink = onHangEpisode
        guard sink != nil || recorder != nil || fatal != nil || episodeSink != nil else { return }
        // A fresh sample: the stall sample is from the first threshold, this one from the hang.
        let sampled = sampleHang(beat: beat, duration: duration, now: now, sampler: sampler, crashKeys: crashKeys, trace: trace)
        let hang = sampled.hang
        recorder?.begin(beat: beat, elapsed: duration, main: hang.addresses, others: hang.otherThreads, phase: hang.phase)
        if sampled.stillBlocked { fatal?.began(hang, now &- elapsedNanos) }
        if let episodeSink {
            state.episodeReport = hang
            episodeSink(.blocked(hang, previous: nil))
        }
        if let sink {
            state.lastReportNanos = now
            sink(hang)
        }
    }

    /// Whether the main thread was inside the Chromium message pump, from the crash keys read while it was
    /// suspended: the trace runtime's `in_cef_pump` key (``CmuxNextTrace/CrashKeySlot/inCEFPump``), which the
    /// pump sets in whichever process runs it, or the app crash keys' CEF state at
    /// ``CrashKeySlots/CEFState/inPump``. The pump runs on main, so it is a phase of the main thread's
    /// episode, not a hang-watch scope (task 077).
    static func inCEFPump(cefState: UInt64, pumpKey: UInt64) -> Bool {
        pumpKey != 0 || cefState == CrashKeySlots.CEFState.inPump.rawValue
    }

    /// The main-thread phase a stall or hang record names: `cef_pump` inside the Chromium message pump
    /// (``inCEFPump(cefState:pumpKey:)``); nil otherwise.
    static func phaseLabel(inCEFPump: Bool) -> String? {
        inCEFPump ? "cef_pump" : nil
    }

    /// What a stall record inside the Chromium message pump adds to its details: `cef=true` and the phase.
    static let cefPumpDetails: [String: JSONValue] = ["cef": .bool(true), "phase": .string("cef_pump")]

    /// A main-thread hang in progress: how long the main thread has been
    /// busy so far, and its stack (return addresses, innermost first).
    public struct Hang: Sendable {
        public var duration: Duration
        public var addresses: [UInt]
        /// Every other thread's stack, sampled right after the main thread's: a main thread
        /// that waits on a lock or a reply shows only the wait, and the holder is in here
        /// (``ThreadStackSampler/sampleOtherThreads(excluding:maxFrames:)``).
        public var otherThreads: [ThreadSample] = []
        /// What the main thread was in when sampled (``phaseLabel(inCEFPump:)``): `cef_pump` inside the
        /// Chromium message pump; nil otherwise, with no crash keys attached, or when the stall ended first.
        public var phase: String?
        /// The sample caught the main thread inside the Chromium message pump (``inCEFPump(cefState:pumpKey:)``):
        /// the Sentry tag `hang.cef`.
        public var cef = false
        /// The scheduled task the sample caught (owner, class, location) and the turn so far; its task
        /// is nil (`unattributed`) when no scheduled task ran or the stall ended before the sample.
        public var attribution = HangAttribution(task: nil, turnNanos: 0)
        /// The launch phase the hang ran in before startup completed (`startup_phase`, ``startupTasks``); nil after.
        public var startupPhase: String?
        /// The `main()` step or startup task running when sampled (`startup_task`); nil between tasks or after startup.
        public var startupTask: String?
    }

    /// A hang episode's checkpoint or end, to its file, to ``fatalHangs`` and to ``onHangEpisode``
    /// (``HangEpisodeTracker/Event/began`` is
    /// ``reportHang(beat:elapsedNanos:now:sampler:crashKeys:trace:state:)``, in `checkHang`). An ended
    /// stall's duration is the exact one the main thread recorded when it resumed. A checkpoint samples
    /// the stacks only for ``onHangEpisode``, and only `sampler`'s (nil: no sample). Watchdog thread only.
    func handle(_ event: HangEpisodeTracker.Event, sampler: ThreadStackSampler?, crashKeys: CrashKeySlots? = nil,
                trace: TraceRuntime? = nil, state: inout HangState) {
        switch event {
        case .began:
            break
        case let .progressed(beat, elapsed):
            let duration = Duration.nanoseconds(Int64(clamping: elapsed))
            episodes?.update(beat: beat, duration: duration, ongoing: true)
            fatalHangs?.progressed(elapsed)
            guard let episodeSink = onHangEpisode else { return }
            let sampled = sampleHang(beat: beat, duration: duration, now: uptime(), sampler: sampler, crashKeys: crashKeys, trace: trace)
            guard sampled.stillBlocked else { return }
            let previous = state.episodeReport?.duration
            state.episodeReport = sampled.hang
            episodeSink(.blocked(sampled.hang, previous: previous))
        case let .ended(beat, lastElapsed):
            fatalHangs?.ended() // first: the run is not stuck any more, before the episode file is rewritten
            let duration = Duration.nanoseconds(Int64(clamping: closeEpisode(beat: beat, lastElapsedNanos: lastElapsed)))
            episodes?.update(beat: beat, duration: duration, ongoing: false)
            let lastReport = state.episodeReport
            state.episodeReport = nil
            onHangEpisode?(.ended(duration: duration, lastReport: lastReport))
        }
    }

    /// The main thread's stack and every other thread's, for the stall of `beat`, with the main thread's
    /// phase, scheduled task and launch tag (``startupTasks``). The beat and the phase are read while the main thread is suspended (atomics
    /// only): `stillBlocked` is false when the stall had ended, and the hang then has no main-thread stack,
    /// phase or task. Watchdog thread only.
    private func sampleHang(beat: UInt64, duration: Duration, now: UInt64, sampler: ThreadStackSampler?, crashKeys: CrashKeySlots?,
                            trace: TraceRuntime?) -> (hang: Hang, stillBlocked: Bool) {
        var stillBlocked = true
        var inPump = false
        let board = boardSink.withLock { $0 }
        var scope = board?.hangScope ?? .noTask
        var startup = StartupStallTag(startupTasks?.read())
        let sampled = sampler?.sample { _ in
            stillBlocked = beatSequence.load(ordering: .acquiring) == beat
            inPump = Self.inCEFPump(cefState: crashKeys?.value(.cefState) ?? 0, pumpKey: trace?.crashKey(.inCEFPump) ?? 0)
            scope = board?.hangScope ?? .noTask
            startup = StartupStallTag(startupTasks?.read())
        } ?? []
        let cef = stillBlocked && inPump
        let others = sampler.map { ThreadStackSampler.sampleOtherThreads(excluding: $0.thread) } ?? []
        let reading = startup.reading
        let hang = Hang(duration: duration, addresses: stillBlocked ? sampled : [], otherThreads: others,
                        phase: Self.phaseLabel(inCEFPump: cef), cef: cef,
                        attribution: hangAttribution(scope, stillBlocked: stillBlocked, now: now),
                        startupPhase: reading.stallPhase, startupTask: reading.stallPhase == nil ? nil : reading.taskName)
        return (hang, stillBlocked)
    }

    /// The episode of `beat` ended: its exact length, which the main thread recorded in
    /// ``hangEnds`` when the stall ended (every stall of a hang's length, whether or not the
    /// watchdog had opened its episode yet), taken out of the list; else the last length the
    /// watchdog saw. Watchdog thread.
    func closeEpisode(beat: UInt64, lastElapsedNanos: UInt64) -> UInt64 {
        let end = hangEnds.withLock { ends in ends.firstIndex { $0.beat == beat }.map { ends.remove(at: $0) } }
        return max(end?.nanos ?? 0, lastElapsedNanos)
    }
}
