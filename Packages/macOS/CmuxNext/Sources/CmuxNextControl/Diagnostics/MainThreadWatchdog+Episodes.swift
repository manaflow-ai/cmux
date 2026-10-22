import os
import CmuxNextCompat

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
    func reportHang(beat: UInt64, elapsedNanos: UInt64, now: UInt64, sampler: ThreadStackSampler?, lastReportNanos: inout UInt64?) {
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
        logger.fault("main thread hang: busy \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting")
        let due = lastReportNanos.map { now >= $0 &+ hangIntervalNanos } ?? true
        let sink = due ? onHang : nil
        let recorder = episodes
        guard sink != nil || recorder != nil else { return }
        // A fresh sample: the stall sample is from the first threshold, this one from the hang.
        // Taken only while the stall still runs: the beat is read while the main thread is suspended.
        var stillBlocked = true
        let sampled = sampler?.sample { _ in stillBlocked = beatSequence.load(ordering: .acquiring) == beat } ?? []
        let addresses = stillBlocked ? sampled : []
        let others = sampler.map { ThreadStackSampler.sampleOtherThreads(excluding: $0.thread) } ?? []
        recorder?.begin(beat: beat, elapsed: duration, main: addresses, others: others)
        if let sink {
            lastReportNanos = now
            sink(Hang(duration: duration, addresses: addresses, otherThreads: others))
        }
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
