/// The viewer inputs whose effect a host frame shows: the newest input that changed the picture, and which of the
/// ``RemoteInputLatency/capacity`` inputs up to it did. An input that changed nothing (a key-up, a modifier, a key
/// the host ignores) is not in it, so no frame times it.
///
/// Chrome reports an input's `EventLatency` only for a frame that has damage from it; an event without damage
/// gets no sample (cc/metrics/events_metrics_manager.cc keeps an event's metrics only when handling it changed
/// the frame). The host keeps one echo, marks each input that damages the picture
/// (``inputDamaged(_:)``) and stamps every frame it captures with the echo at capture. The marks are cumulative,
/// so a frame the viewer never shows does not lose its inputs: the next shown frame carries them too.
///
/// Iterating yields the damaging inputs' sequence numbers, newest first.
///
/// ```swift
/// echo.inputDamaged(sequence)
/// for sequence in frame.inputEcho { latency.sentMicros(sequence) }
/// ```
public nonisolated struct RemoteInputEcho: Sendable, Hashable, Sequence {
    /// No input: the frame changed by itself, or the host does not say (`cmux.rd/1` frames carry no echo yet).
    public static let noInput = RemoteInputEcho()

    /// The newest input that changed the picture (``RemoteInputLatency/Sequencer`` numbering); 0 for none.
    public private(set) var newest: UInt32
    /// Bit `i` set: input `newest - i` changed the picture.
    public private(set) var damaged: UInt64

    /// No input.
    public init() {
        newest = 0
        damaged = 0
    }

    init(newest: UInt32, damaged: UInt64) {
        self.newest = newest
        self.damaged = newest == 0 ? 0 : damaged
    }

    /// Marks input `sequence` as one that changed the picture (host side). Sequence 0 is not an input; an input
    /// more than ``RemoteInputLatency/capacity`` older than ``newest`` is no longer tracked.
    public mutating func inputDamaged(_ sequence: UInt32) {
        guard sequence != 0 else { return }
        let width = UInt32(UInt64.bitWidth)
        if sequence > newest {
            let ahead = sequence - newest
            damaged = newest == 0 || ahead >= width ? 1 : (damaged << UInt64(ahead)) | 1
            newest = sequence
        } else if newest - sequence < width {
            damaged |= UInt64(1) << UInt64(newest - sequence)
        }
    }

    /// The damaging inputs newer than `shown`, the newest input an earlier shown frame showed.
    func inputs(after shown: UInt32) -> RemoteInputEcho {
        guard newest > shown else { return .noInput }
        let fresh = newest - shown
        let mask = fresh >= UInt32(UInt64.bitWidth) ? damaged : damaged & ((UInt64(1) << UInt64(fresh)) - 1)
        return RemoteInputEcho(newest: newest, damaged: mask)
    }

    public func makeIterator() -> Iterator {
        Iterator(newest: newest, remaining: damaged)
    }

    /// The damaging inputs' sequence numbers, newest first.
    public nonisolated struct Iterator: IteratorProtocol {
        let newest: UInt32
        var remaining: UInt64

        public mutating func next() -> UInt32? {
            guard remaining != 0 else { return nil }
            let back = UInt32(remaining.trailingZeroBitCount)
            remaining &= remaining - 1
            return newest - back
        }
    }
}
