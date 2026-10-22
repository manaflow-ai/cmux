/// The watchdog thread's hang episodes: a stall that has lasted the hang threshold
/// opens one, and the main thread answering again closes it.
///
/// One episode per stall: a stall is one heartbeat (``MainThreadWatchdog``'s beat
/// sequence), and the beat moves only when the main thread runs its loop again, so an
/// episode fires once and the tracker re-arms only after the main thread recovered.
/// While an episode runs it reports checkpoints at doubling durations (4 s, 8 s, 16 s, ...),
/// so a file written before the app is killed mid-hang still says how long it lasted.
/// Plain state, no clock or thread of its own: the watchdog passes what it read.
struct HangEpisodeTracker: Equatable {
    enum Event: Equatable {
        /// A stall crossed the hang threshold: sample the main thread and open the file.
        case began(beat: UInt64, elapsedNanos: UInt64)
        /// The stall is still running at a checkpoint: rewrite its duration.
        case progressed(beat: UInt64, elapsedNanos: UInt64)
        /// The main thread answered again (or the watchdog stopped): finalize the file.
        /// `lastElapsedNanos` is the duration at the last look; the exact one is the
        /// stall the main thread recorded when it resumed.
        case ended(beat: UInt64, lastElapsedNanos: UInt64)
    }

    private struct Open: Equatable {
        var beat: UInt64
        var elapsedNanos: UInt64
        var nextCheckpointNanos: UInt64
    }

    let hangNanos: UInt64
    private var open: Open?

    init(hangNanos: UInt64) {
        self.hangNanos = max(hangNanos, 1)
    }

    var openBeat: UInt64? { open?.beat }

    /// One look at the main thread: `beat` is its heartbeat sequence, `busy` false while
    /// its run loop sleeps, `elapsedNanos` the time since that heartbeat.
    mutating func observe(beat: UInt64, busy: Bool, elapsedNanos: UInt64) -> [Event] {
        var events: [Event] = []
        if let current = open, current.beat != beat || !busy {
            events.append(.ended(beat: current.beat, lastElapsedNanos: current.elapsedNanos))
            open = nil
        }
        guard busy else { return events }
        if var current = open {
            current.elapsedNanos = max(current.elapsedNanos, elapsedNanos)
            if elapsedNanos >= current.nextCheckpointNanos {
                events.append(.progressed(beat: beat, elapsedNanos: elapsedNanos))
                current.nextCheckpointNanos = elapsedNanos.saturatingMultiplication(2)
            }
            open = current
        } else if elapsedNanos >= hangNanos {
            events.append(.began(beat: beat, elapsedNanos: elapsedNanos))
            open = Open(beat: beat, elapsedNanos: elapsedNanos, nextCheckpointNanos: elapsedNanos.saturatingMultiplication(2))
        }
        return events
    }

    /// The watchdog is stopping: closes the open episode, if any.
    mutating func finish() -> Event? {
        defer { open = nil }
        return open.map { .ended(beat: $0.beat, lastElapsedNanos: $0.elapsedNanos) }
    }
}
