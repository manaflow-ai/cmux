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
    /// every other thread, opens the hang file, reports the episode (``onHangEpisode``), and
    /// reports the hang (``onHang``) at most once per `hangReportInterval`. Watchdog thread only.
    func reportHang(beat: UInt64, elapsedNanos: UInt64, now: UInt64, sampler: ThreadStackSampler?, state: inout HangState) {
        let duration = Duration.nanoseconds(Int64(clamping: elapsedNanos))
        logger.fault("main thread hang: busy \(duration.fractionalMilliseconds, format: .fixed(precision: 0)) ms and counting")
        let due = state.lastReportNanos.map { now >= $0 &+ hangIntervalNanos } ?? true
        let sink = due ? onHang : nil
        let recorder = episodes
        let episodeSink = onHangEpisode
        guard sink != nil || recorder != nil || episodeSink != nil else { return }
        // A fresh sample: the stall sample is from the first threshold, this one from the hang.
        let sampled = sampleHang(beat: beat, duration: duration, sampler: sampler)
        let hang = sampled.stillBlocked ? sampled.hang : Hang(duration: duration, addresses: [], otherThreads: sampled.hang.otherThreads)
        recorder?.begin(beat: beat, elapsed: duration, main: hang.addresses, others: hang.otherThreads)
        if let episodeSink {
            state.episodeReport = hang
            episodeSink(.blocked(hang, previous: nil))
        }
        if let sink {
            state.lastReportNanos = now
            sink(hang)
        }
    }

    /// A hang episode's checkpoint or end, to its file and to ``onHangEpisode``
    /// (``HangEpisodeTracker/Event/began`` is ``reportHang(beat:elapsedNanos:now:sampler:state:)``,
    /// in `checkHang`). An ended stall's duration is the exact one the main thread recorded when
    /// it resumed. Watchdog thread only.
    func handle(_ event: HangEpisodeTracker.Event, sampler: ThreadStackSampler?, state: inout HangState) {
        switch event {
        case .began:
            break
        case let .progressed(beat, elapsed):
            let duration = Duration.nanoseconds(Int64(clamping: elapsed))
            episodes?.update(beat: beat, duration: duration, ongoing: true)
            guard let episodeSink = onHangEpisode else { return }
            let sampled = sampleHang(beat: beat, duration: duration, sampler: sampler)
            guard sampled.stillBlocked else { return }
            let previous = state.episodeReport?.duration
            state.episodeReport = sampled.hang
            episodeSink(.blocked(sampled.hang, previous: previous))
        case let .ended(beat, lastElapsed):
            let duration = Duration.nanoseconds(Int64(clamping: closeEpisode(beat: beat, lastElapsedNanos: lastElapsed)))
            episodes?.update(beat: beat, duration: duration, ongoing: false)
            let lastReport = state.episodeReport
            state.episodeReport = nil
            onHangEpisode?(.ended(duration: duration, lastReport: lastReport))
        }
    }

    /// The main thread's stack and every other thread's, for the stall of `beat`. The main
    /// thread's beat is read while it is suspended: `stillBlocked` is false when the stall had
    /// ended, and its sample is then of other work. Watchdog thread only.
    private func sampleHang(beat: UInt64, duration: Duration, sampler: ThreadStackSampler?) -> (hang: Hang, stillBlocked: Bool) {
        var stillBlocked = true
        let addresses = sampler?.sample { _ in stillBlocked = beatSequence.load(ordering: .acquiring) == beat } ?? []
        let others = sampler.map { ThreadStackSampler.sampleOtherThreads(excluding: $0.thread) } ?? []
        return (Hang(duration: duration, addresses: addresses, otherThreads: others), stillBlocked)
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
