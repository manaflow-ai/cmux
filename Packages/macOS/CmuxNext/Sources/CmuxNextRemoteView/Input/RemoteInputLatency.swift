public import CmuxNextTrace
import CmuxNextCompat
import CmuxNextSignposts

/// When the remote desktop viewer sent each of its recent input events, by the viewer's sequence number, so the
/// presenter can time an input to the first frame that shows it (`remote.input_to_present`).
///
/// Chrome's model: an input's `EventLatency` ends at the presentation time of the first frame that contains its
/// effect (cc/metrics/event_metrics.h, cc/metrics/compositor_frame_reporter.cc); the event's identity rides with the
/// frame (ui/latency/latency_info.h). Here the frame carries ``RemoteAccessUnit/inputEcho``, the newest sequence the
/// host had applied when it captured the picture, and this table answers when that sequence left the viewer.
///
/// The viewer numbers its events itself (``Sequencer``), from 1 in send order, independent of the `cmux.rd/1` wire
/// sequence. One writer (the input controller, on the main actor) and one reader (the present log) share
/// ``capacity`` one-word atomic slots: each holds the sequence in its high 32 bits and the send time in
/// microseconds, truncated to 32 bits, in its low 32 bits, so a read never sees half of a write and an overwritten
/// slot says so. No lock, allocation or system call after init.
///
/// ```swift
/// latency.recordSent(sequencer.next())
/// latency.sentMicros(frame.inputEcho)
/// ```
public nonisolated final class RemoteInputLatency: Sendable {
    /// Inputs the table remembers: an input whose slot a later one took is no longer timed.
    public static let capacity = 64

    private nonisolated final class Slot: Sendable {
        let word = Atomic<UInt64>(0)
    }

    /// The trace runtime the remote stream's trace points and histograms go to.
    public let runtime: TraceRuntime
    private let clock: TraceClock
    private let slots: [Slot]

    /// A table whose `remote.input` points and send times use `runtime` and `clock` (tests pass their own).
    public init(runtime: TraceRuntime = .shared, clock: TraceClock = TraceClock()) {
        self.runtime = runtime
        self.clock = clock
        slots = (0..<Self.capacity).map { _ in Slot() }
    }

    /// Records that input `sequence` leaves the viewer now, and writes its `remote.input` point. Sequence 0 is
    /// not an input and is ignored.
    public func recordSent(_ sequence: UInt32) {
        guard sequence != 0 else { return }
        slot(sequence).word.store(UInt64(sequence) << 32 | UInt64(nowMicros()), ordering: .releasing)
        runtime.event(.remoteInput, arg0: UInt64(sequence))
    }

    /// When input `sequence` was sent, in truncated trace microseconds (compare with ``nowMicros()`` by wrapping
    /// subtraction), or nil when it was never recorded or a later input took its slot.
    public func sentMicros(_ sequence: UInt32) -> UInt32? {
        guard sequence != 0 else { return nil }
        let word = slot(sequence).word.load(ordering: .acquiring)
        guard UInt32(truncatingIfNeeded: word >> 32) == sequence else { return nil }
        return UInt32(truncatingIfNeeded: word)
    }

    /// The trace clock now, in microseconds truncated to 32 bits (it wraps every 71 minutes; a latency is a
    /// wrapping difference of two such values).
    public func nowMicros() -> UInt32 {
        UInt32(truncatingIfNeeded: clock.nowNanos() / 1_000)
    }

    private func slot(_ sequence: UInt32) -> Slot {
        slots[Int(sequence % UInt32(Self.capacity))]
    }
}

extension RemoteInputLatency {
    /// The viewer's input numbering: 1, 2, 3, ... in send order, never 0 (0 means "no input" in
    /// ``RemoteAccessUnit/inputEcho``). The input controller numbers what it sends; a host that numbers what it
    /// applies the same way (the mock host's sink) echoes the same numbers.
    public nonisolated struct Sequencer: Sendable, Equatable {
        private var last: UInt32 = 0

        /// A sequencer whose first number is 1.
        public init() {}

        /// The next input's number.
        public mutating func next() -> UInt32 {
            last = last == .max ? 1 : last + 1
            return last
        }
    }
}
