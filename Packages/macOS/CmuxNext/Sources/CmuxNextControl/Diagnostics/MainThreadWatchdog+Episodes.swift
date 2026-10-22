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
        openEpisode(beat: beat)
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
        logger.fault("main thread hang: busy \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting")
        let due = lastReportNanos.map { now >= $0 &+ hangIntervalNanos } ?? true
        let sink = due ? onHang : nil
        let recorder = episodes
        guard sink != nil || recorder != nil else { return }
        // A fresh sample: the stall sample is from the first threshold, this one from the hang.
        let addresses = sampler?.sample() ?? []
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

    /// Marks `beat` as the open episode: from now on only that stall's end fills ``episodeEnd``,
    /// so a later short stall cannot overwrite it. Watchdog thread.
    func openEpisode(beat: UInt64) {
        episodeEnd.withLock { $0 = nil }
        episodeBeat.store(beat, ordering: .releasing)
    }

    /// The episode of `beat` ended: its exact length, which the main thread recorded under the
    /// lock when the stall ended, else the last length the watchdog saw (the stall ended before
    /// ``openEpisode(beat:)`` published it). Clears the slot. Watchdog thread.
    func closeEpisode(beat: UInt64, lastElapsedNanos: UInt64) -> UInt64 {
        episodeBeat.store(.max, ordering: .releasing)
        let end = episodeEnd.withLock { end in defer { end = nil }; return end }
        guard let end, end.beat == beat else { return lastElapsedNanos }
        return max(end.nanos, lastElapsedNanos)
    }
}
