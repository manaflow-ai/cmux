#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// Ack-based pacing of one page's input to the Chromium Host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1, Coalescing).
///
/// A pointer move or a wheel tick leaves at once when none of its kind is in
/// flight, so the first wheel tick of a gesture leaves in the event's own turn.
/// While one is in flight (sent, not yet dispatched by the host), later ones
/// wait in one slot: the latest move replaces the waiting move; wheel ticks add
/// their deltas into the waiting tick of the same scroll phase, momentum phase,
/// modifiers and precision (the frame's flags), and a tick of another phase waits behind it. The
/// host's ack (`kOpInputAck`, sent when its UI thread dispatched the frame, not
/// when the renderer handled it) sends the next waiting one. That is Chrome's
/// browser side: `MouseWheelEventQueue` keeps one wheel event in flight and
/// coalesces only events queued behind an unacked one
/// (components/input/mouse_wheel_event_queue.cc), and holding nothing back
/// when nothing is in flight costs no latency, where a per-frame flush would
/// hold the first event up to a frame.
///
/// Keys, clicks, exits and every other frame pass at once and are never
/// coalesced or held. What waits leaves first, in the same turn: the waiting
/// move and wheel ticks go out in the order they came, then the frame
/// (``Release``), as Blink's `MainThreadEventQueue` dispatches the coalesced
/// continuous events queued before a discrete one ahead of it
/// (third_party/blink/renderer/platform/widget/input/main_thread_event_queue.cc).
/// So the last move of a drag reaches the page before its mouse-up, and a
/// key after a move reaches it after the move. Each such flush puts one more
/// move (or the waiting wheel ticks) in flight while the earlier one is
/// unacked; ``Stats/flushedAhead`` counts them.
///
/// Main actor in use (the page view's), but a plain value: the tests drive it alone.
nonisolated struct ChromiumHostInputPacer: Sendable {
    /// The kinds that wait for an ack.
    nonisolated enum Paced: Equatable, Sendable {
        case move
        case wheel
    }

    /// What to send for one submitted frame, in this order: ``ahead`` (the moves and wheel
    /// ticks that waited, oldest first), then ``frame`` (nil when it waits or was dropped).
    nonisolated struct Release: Equatable, Sendable {
        var ahead: [ChromiumHostFrame] = []
        var frame: ChromiumHostFrame?
    }

    /// Counts for `debug.chromium_host`.
    nonisolated struct Stats: Equatable, Sendable {
        /// Moves and wheel ticks sent to the host.
        var sent: UInt64 = 0
        /// Moves and wheel ticks folded into a waiting one.
        var coalesced: UInt64 = 0
        /// Waiting moves and wheel ticks sent ahead of a key, click, exit or other frame.
        var flushedAhead: UInt64 = 0
        /// Paced frames the writer could not take (no host, a dropped tick): no ack comes for them.
        var unsent: UInt64 = 0
        /// Wheel ticks dropped over ``ChromiumHostInputPacer/waitingWheelLimit``.
        var dropped: UInt64 = 0
        var acks: UInt64 = 0
        /// Acks with nothing of their kind in flight (a host that acks twice).
        var unexpectedAcks: UInt64 = 0
        /// The most moves and wheel ticks ever in flight at once: 1 each while
        /// no discrete frame flushes a waiting one ahead of it.
        var maxMovesInFlight = 0
        var maxWheelsInFlight = 0
    }

    /// Wheel ticks of distinct phases that may wait behind the one in flight.
    /// A gesture has a few phase changes (began, changed, ended, then momentum
    /// began, changed, ended); more than this waiting means the host stopped
    /// dispatching, and a newer tick that cannot fold is dropped and counted.
    static let waitingWheelLimit = 32

    private(set) var stats = Stats()
    private(set) var movesInFlight = 0
    private(set) var wheelsInFlight = 0
    private var waitingMove: Waiting?
    /// Oldest first; consecutive ticks of one phase are folded into one.
    private var waitingWheels: [Waiting] = []
    /// Arrival order of submitted frames, so a flush keeps the move and the wheel ticks in order.
    private var arrivals: UInt64 = 0
    /// The input seq of the newest move and wheel tick written (``written(_:seq:)``).
    private var lastMoveSeq: UInt32?
    private var lastWheelSeq: UInt32?

    /// A waiting frame and the arrival of its newest part.
    private nonisolated struct Waiting: Equatable, Sendable {
        var frame: ChromiumHostFrame
        var arrival: UInt64
    }

    /// Moves and wheel ticks waiting for an ack.
    var waitingCount: Int { (waitingMove == nil ? 0 : 1) + waitingWheels.count }

    /// What to send for `frame` now: nothing while it waits behind one of its kind in flight (or
    /// was dropped), the frame alone, or, for a frame that does not wait, what waited and then it.
    mutating func submit(_ frame: ChromiumHostFrame) -> Release { // perf-hot: 1us cef-host-input (every key, click, move and wheel of a hosted page)
        arrivals &+= 1
        switch Self.paced(frame) {
        case .move?:
            guard movesInFlight > 0 else { return Release(frame: sending(frame, .move)) }
            if waitingMove != nil { stats.coalesced += 1 }
            waitingMove = Waiting(frame: frame, arrival: arrivals)
            return Release()
        case .wheel?:
            guard wheelsInFlight > 0 else { return Release(frame: sending(frame, .wheel)) }
            if let last = waitingWheels.indices.last, Self.fold(frame, into: &waitingWheels[last].frame) {
                waitingWheels[last].arrival = arrivals
                stats.coalesced += 1
            } else if waitingWheels.count < Self.waitingWheelLimit {
                waitingWheels.append(Waiting(frame: frame, arrival: arrivals))
            } else {
                stats.dropped += 1
            }
            return Release()
        case nil:
            guard waitingMove != nil || !waitingWheels.isEmpty else { return Release(frame: frame) }
            return Release(ahead: flushWaiting(), frame: frame)
        }
    }

    /// The writer did not take the paced `kind` this pacer just released (no host attached, a
    /// ring that dropped it): no ack will come for it, so it is no longer in flight.
    mutating func unsent(_ kind: Paced) {
        stats.unsent += 1
        switch kind {
        case .move: movesInFlight = max(0, movesInFlight - 1)
        case .wheel: wheelsInFlight = max(0, wheelsInFlight - 1)
        }
    }

    /// The writer took the paced `kind` this pacer just released, with input seq `seq`.
    mutating func written(_ kind: Paced, seq: UInt32) {
        switch kind {
        case .move: lastMoveSeq = seq
        case .wheel: lastWheelSeq = seq
        }
    }

    /// The host dispatched the page's `kind` in flight with input seq `seq` (nil: the oldest): the
    /// next waiting one to send, if any. An ack of the newest one written settles every one of its
    /// kind before it too: the writer's backlog may have folded them into it (the ring was full).
    mutating func acked(_ kind: Paced, seq: UInt32? = nil) -> ChromiumHostFrame? {
        stats.acks += 1
        switch kind {
        case .move:
            guard movesInFlight > 0 else {
                stats.unexpectedAcks += 1
                return nil
            }
            movesInFlight = seq != nil && seq == lastMoveSeq ? 0 : movesInFlight - 1
            guard movesInFlight == 0, let next = waitingMove else { return nil }
            waitingMove = nil
            return sending(next.frame, .move)
        case .wheel:
            guard wheelsInFlight > 0 else {
                stats.unexpectedAcks += 1
                return nil
            }
            wheelsInFlight = seq != nil && seq == lastWheelSeq ? 0 : wheelsInFlight - 1
            guard wheelsInFlight == 0, !waitingWheels.isEmpty else { return nil }
            return sending(waitingWheels.removeFirst().frame, .wheel)
        }
    }

    /// A new host (or none): nothing is in flight, and what waited was for the old one.
    mutating func reset() {
        movesInFlight = 0
        wheelsInFlight = 0
        lastMoveSeq = nil
        lastWheelSeq = nil
        waitingMove = nil
        waitingWheels.removeAll(keepingCapacity: true)
    }

    /// Every waiting move and wheel tick, in arrival order, now in flight: what must leave before
    /// input that does not pass through the pacer (a text input op).
    mutating func flush() -> [ChromiumHostFrame] {
        waitingCount == 0 ? [] : flushWaiting()
    }

    /// Every waiting move and wheel tick, in arrival order, now in flight.
    private mutating func flushWaiting() -> [ChromiumHostFrame] {
        var out: [ChromiumHostFrame] = []
        out.reserveCapacity(waitingWheels.count + 1)
        var move = waitingMove
        for wheel in waitingWheels {
            if let waiting = move, waiting.arrival < wheel.arrival {
                out.append(sending(waiting.frame, .move))
                move = nil
            }
            out.append(sending(wheel.frame, .wheel))
        }
        if let waiting = move { out.append(sending(waiting.frame, .move)) }
        stats.flushedAhead += UInt64(out.count)
        waitingMove = nil
        waitingWheels.removeAll(keepingCapacity: true)
        return out
    }

    private mutating func sending(_ frame: ChromiumHostFrame, _ kind: Paced) -> ChromiumHostFrame {
        stats.sent += 1
        switch kind {
        case .move:
            movesInFlight += 1
            stats.maxMovesInFlight = max(stats.maxMovesInFlight, movesInFlight)
        case .wheel:
            wheelsInFlight += 1
            stats.maxWheelsInFlight = max(stats.maxWheelsInFlight, wheelsInFlight)
        }
        return frame
    }

    /// A pointer move (mouse phase 0) or a wheel tick: the frames the host acks
    /// (`AckBatch::IsPaced`, ChromiumHost/src/host_input.h).
    static func paced(_ frame: ChromiumHostFrame) -> Paced? {
        switch frame.kind {
        case .mouse: return frame.v[2] == 0 ? .move : nil
        case .wheel: return .wheel
        default: return nil
        }
    }

    /// Adds `next`'s deltas into `waiting` when both are ticks of one phase:
    /// the same scroll phase (v4), momentum phase (v5) and flags (modifiers and
    /// ``ChromiumHostFrame/wheelPrecise``, p04-input-063's wire), as Blink's
    /// `WebMouseWheelEvent::CanCoalesce`. The newest position and time win.
    static func fold(_ next: ChromiumHostFrame, into waiting: inout ChromiumHostFrame) -> Bool {
        guard next.rawKind == ChromiumHostFrame.Kind.wheel.rawValue, waiting.rawKind == next.rawKind,
              next.v[4] == waiting.v[4], next.v[5] == waiting.v[5], next.flags == waiting.flags else { return false }
        let dx = waiting.v[2], dy = waiting.v[3]
        waiting = next
        waiting.v[2] = Int32(clamping: Int64(dx) + Int64(next.v[2]))
        waiting.v[3] = Int32(clamping: Int64(dy) + Int64(next.v[3]))
        return true
    }
}
#endif
