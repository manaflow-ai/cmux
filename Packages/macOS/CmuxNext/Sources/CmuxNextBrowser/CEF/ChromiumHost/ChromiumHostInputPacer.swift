#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.

/// Ack-based pacing of one page's input to the Chromium Host
/// (plans/cmux-next/chrome-parity/p01-process.md 3.1, Coalescing; task p01-process-042).
///
/// A pointer move or a wheel tick leaves at once when none of its kind is in
/// flight, so the first wheel tick of a gesture leaves in the event's own turn.
/// While one is in flight (sent, not yet dispatched by the host), later ones
/// wait in one slot: the latest move replaces the waiting move; wheel ticks add
/// their deltas into the waiting tick of the same scroll phase, momentum phase,
/// modifiers and precision, and a tick of another phase waits behind it. The
/// host's ack (`kOpInputAck`, sent when its UI thread dispatched the frame, not
/// when the renderer handled it) sends the next waiting one. That is Chrome's
/// browser side: `MouseWheelEventQueue` keeps one wheel event in flight and
/// coalesces only events queued behind an unacked one
/// (components/input/mouse_wheel_event_queue.cc), and holding nothing back
/// when nothing is in flight costs no latency, where a per-frame flush would
/// hold the first event up to a frame.
///
/// Keys, clicks, exits and every other frame pass at once and are never
/// coalesced. A click or an exit makes a waiting move stale (it carries its own
/// position), so the waiting move is dropped and counted rather than sent after it.
///
/// Main actor in use (the page view's), but a plain value: the tests drive it alone.
nonisolated struct ChromiumHostInputPacer: Sendable {
    /// The kinds that wait for an ack.
    enum Paced: Equatable, Sendable {
        case move
        case wheel
    }

    /// Counts for `debug.chromium_host`.
    struct Stats: Equatable, Sendable {
        /// Moves and wheel ticks sent to the host.
        var sent: UInt64 = 0
        /// Moves and wheel ticks folded into a waiting one.
        var coalesced: UInt64 = 0
        /// Waiting moves dropped because a click or an exit came after them.
        var superseded: UInt64 = 0
        /// Wheel ticks dropped over ``ChromiumHostInputPacer/waitingWheelLimit``.
        var dropped: UInt64 = 0
        var acks: UInt64 = 0
        /// Acks with nothing of their kind in flight (a host that acks twice).
        var unexpectedAcks: UInt64 = 0
        /// The most moves and wheel ticks ever in flight at once: 1 each.
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
    private var waitingMove: ChromiumHostFrame?
    /// Oldest first; consecutive ticks of one phase are folded into one.
    private var waitingWheels: [ChromiumHostFrame] = []

    /// Moves and wheel ticks waiting for an ack.
    var waitingCount: Int { (waitingMove == nil ? 0 : 1) + waitingWheels.count }

    /// The frame to send for `frame` now, or nil when it waits (or was dropped).
    mutating func submit(_ frame: ChromiumHostFrame) -> ChromiumHostFrame? { // perf-hot: 1us cef-host-input (every key, click, move and wheel of a hosted page)
        switch Self.paced(frame) {
        case .move?:
            guard movesInFlight > 0 else { return sending(frame, .move) }
            if waitingMove != nil { stats.coalesced += 1 }
            waitingMove = frame
            return nil
        case .wheel?:
            guard wheelsInFlight > 0 else { return sending(frame, .wheel) }
            if let last = waitingWheels.indices.last, Self.fold(frame, into: &waitingWheels[last]) {
                stats.coalesced += 1
            } else if waitingWheels.count < Self.waitingWheelLimit {
                waitingWheels.append(frame)
            } else {
                stats.dropped += 1
            }
            return nil
        case nil:
            if frame.kind == .mouse, waitingMove != nil {
                waitingMove = nil
                stats.superseded += 1
            }
            return frame
        }
    }

    /// The host dispatched the page's `kind` in flight: the next waiting one to send, if any.
    mutating func acked(_ kind: Paced) -> ChromiumHostFrame? {
        stats.acks += 1
        switch kind {
        case .move:
            guard movesInFlight > 0 else {
                stats.unexpectedAcks += 1
                return nil
            }
            movesInFlight -= 1
            guard let next = waitingMove else { return nil }
            waitingMove = nil
            return sending(next, .move)
        case .wheel:
            guard wheelsInFlight > 0 else {
                stats.unexpectedAcks += 1
                return nil
            }
            wheelsInFlight -= 1
            guard !waitingWheels.isEmpty else { return nil }
            return sending(waitingWheels.removeFirst(), .wheel)
        }
    }

    /// A new host (or none): nothing is in flight, and what waited was for the old one.
    mutating func reset() {
        movesInFlight = 0
        wheelsInFlight = 0
        waitingMove = nil
        waitingWheels.removeAll(keepingCapacity: true)
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
    /// the same scroll phase (v4), momentum phase (v5), precision (ch) and
    /// modifiers. The newest position and time win.
    static func fold(_ next: ChromiumHostFrame, into waiting: inout ChromiumHostFrame) -> Bool {
        guard next.rawKind == ChromiumHostFrame.Kind.wheel.rawValue, waiting.rawKind == next.rawKind,
              next.v[4] == waiting.v[4], next.v[5] == waiting.v[5], next.ch == waiting.ch,
              next.flags == waiting.flags else { return false }
        let dx = waiting.v[2], dy = waiting.v[3]
        waiting = next
        waiting.v[2] = Int32(clamping: Int64(dx) + Int64(next.v[2]))
        waiting.v[3] = Int32(clamping: Int64(dy) + Int64(next.v[3]))
        return true
    }
}
#endif
