import os
import CmuxNextCompat
import CmuxNextWakeups

extension MainThreadWatchdog {
    /// Writes one file per hang episode (``HangEpisodeRecorder``): the main thread's stack at
    /// the hang threshold, finalized with the duration once the main thread answers again.
    /// Nil (the default) writes nothing.
    public var episodes: HangEpisodeRecorder? {
        get { episodeSink.withLock { $0 } }
        set { episodeSink.withLock { $0 = newValue } }
    }

    /// Closes the open episode once the main thread moved past its beat or its run loop
    /// sleeps. A few atomic loads, and nothing when no episode is open. Watchdog thread only.
    func closeRecoveredEpisode(_ tracker: inout HangEpisodeTracker) {
        guard tracker.openBeat != nil else { return }
        let beat = beatSequence.load(ordering: .acquiring)
        for event in tracker.observe(beat: beat, busy: !mainAsleep.load(ordering: .acquiring), elapsedNanos: 0) {
            handle(event)
        }
    }

    /// A stall just crossed the hang threshold (once per stall): samples the main thread and
    /// every other thread, opens the hang file, and reports the hang (``onHang``) at most once
    /// per `hangReportInterval`. Watchdog thread only.
    func reportHang(beat: UInt64, elapsedNanos: UInt64, now: UInt64, sampler: ThreadStackSampler?, crashKeys: CrashKeySlots?,
                    lastReportNanos: inout UInt64?) {
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
        logger.fault("main thread hang: busy \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting")
        let due = lastReportNanos.map { now >= $0 &+ hangIntervalNanos } ?? true
        let sink = due ? onHang : nil
        let recorder = episodes
        guard sink != nil || recorder != nil else { return }
        // A fresh sample: the stall sample is from the first threshold, this one from the hang.
        // Taken only while the stall still runs: the beat and the phase are read while the main thread
        // is suspended (atomics only).
        var stillBlocked = true
        var cefState: UInt64 = 0
        let board = boardSink.withLock { $0 }
        var scope = board?.hangScope ?? .noTask
        var startup = StartupStallTag(startupTasks?.read())
        let sampled = sampler?.sample { _ in
            stillBlocked = beatSequence.load(ordering: .acquiring) == beat
            cefState = crashKeys?.value(.cefState) ?? 0
            scope = board?.hangScope ?? .noTask
            startup = StartupStallTag(startupTasks?.read())
        } ?? []
        let addresses = stillBlocked ? sampled : []
        let phase = stillBlocked ? Self.phaseLabel(cefState: cefState) : nil
        let others = sampler.map { ThreadStackSampler.sampleOtherThreads(excluding: $0.thread) } ?? []
        recorder?.begin(beat: beat, elapsed: duration, main: addresses, others: others, phase: phase)
        if let sink {
            lastReportNanos = now
            let reading = startup.reading
            sink(Hang(duration: duration, addresses: addresses, otherThreads: others, phase: phase,
                      attribution: hangAttribution(scope, stillBlocked: stillBlocked, now: now),
                      startupPhase: reading.stallPhase, startupTask: reading.stallPhase == nil ? nil : reading.taskName))
        }
    }

    /// The main-thread phase a stall or hang record names, from ``CrashKeySlots/Key/cefState`` read while
    /// the main thread was suspended: `cef_pump` while the Chromium message pump runs on it (it runs on
    /// main, so it is a phase of the main thread's episode, not a hang-watch scope); nil otherwise.
    static func phaseLabel(cefState: UInt64) -> String? {
        cefState == CrashKeySlots.CEFState.inPump.rawValue ? "cef_pump" : nil
    }

    /// A main-thread hang in progress: how long the main thread has been
    /// busy so far, and its stack (return addresses, innermost first).
    public struct Hang: Sendable {
        public var duration: Duration
        public var addresses: [UInt]
        /// Every other thread's stack, sampled right after the main thread's: a main thread
        /// that waits on a lock or a reply shows only the wait, and the holder is in here
        /// (``ThreadStackSampler/sampleOtherThreads(excluding:maxFrames:)``).
        public var otherThreads: [ThreadSample] = []
        /// What the main thread was in when sampled (``phaseLabel(cefState:)``): `cef_pump` inside the
        /// Chromium message pump; nil otherwise, with no crash keys attached, or when the stall ended first.
        public var phase: String?
        /// The scheduled task the sample caught (owner, class, location) and the turn so far; its task
        /// is nil (`unattributed`) when no scheduled task ran or the stall ended before the sample.
        public var attribution = HangAttribution(task: nil, turnNanos: 0)
        /// The launch phase the hang ran in before startup completed (`startup_phase`, ``startupTasks``); nil after.
        public var startupPhase: String?
        /// The `main()` step or startup task running when sampled (`startup_task`); nil between tasks or after startup.
        public var startupTask: String?
    }

    /// A hang episode's checkpoint or end, to its file (``HangEpisodeTracker/Event/began``
    /// samples the stacks, in `checkHang`). An ended stall's duration is the exact one the main
    /// thread recorded when it resumed. Watchdog thread only.
    func handle(_ event: HangEpisodeTracker.Event) {
        switch event {
        case .began:
            break
        case let .progressed(beat, elapsed):
            episodes?.update(beat: beat, duration: .nanoseconds(Int64(clamping: elapsed)), ongoing: true)
        case let .ended(beat, lastElapsed):
            let nanos = closeEpisode(beat: beat, lastElapsedNanos: lastElapsed)
            episodes?.update(beat: beat, duration: .nanoseconds(Int64(clamping: nanos)), ongoing: false)
        }
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
