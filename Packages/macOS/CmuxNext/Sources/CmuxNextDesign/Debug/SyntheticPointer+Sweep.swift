#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit
import CmuxNextWakeups

extension SyntheticPointer {
    /// One sweep's result (`debug.pointer_sweep`).
    public struct Sweep: Sendable {
        /// Main-thread ms of each move: the events' delivery and every handler they ran.
        public var moveMs: [Double] = []
        /// Moves that started more than one period after their due time.
        public var late = 0
        /// Moves whose target had no point (not drawn), and moves after which the target showed hovered.
        public var missing = 0
        public var landed = 0
        /// From the first move to the exit.
        public var seconds: Double = 0
        /// Hover areas in the window (walked once, before the first move).
        public var areas = 0

        /// The result as a JSON-ready dictionary.
        public var foundation: [String: Any] {
            ["move_ms": moveMs.map { ($0 * 1_000).rounded() / 1_000 }, "late": late, "missing": missing, "landed": landed,
             "seconds": (seconds * 1_000).rounded() / 1_000, "moves": moveMs.count, "areas": areas]
        }
    }

    /// Moves the pointer `count` times at `hz` moves per second, then out of the window: move `i` goes to
    /// `target(i)`, read at the move (a row that moved is followed). Each move is its own main-actor turn, paced
    /// by the clock (not by the control socket or the display frame), so a 120 Hz sweep makes 120 moves a second
    /// on any display and the main thread is free between them. `landed(i)` says after move `i` whether its
    /// target shows hovered.
    public func sweep(count: Int, hz: Double, target: @MainActor (Int) -> CGPoint?, landed: @MainActor (Int) -> Bool) async -> Sweep {
        var result = Sweep()
        guard count > 0, hz > 0 else { return result }
        let areas = areas()
        result.areas = areas.count
        let clock = ContinuousClock()
        let period = Duration.seconds(1 / hz)
        let start = clock.now
        for index in 0..<count {
            let due = start + period * index
            // wakeup-allow: a debug sweep's pacing, one deadline per move for one debug.pointer_sweep request; it
            // suspends the main actor's task between moves (never blocks the thread) and is not a poll.
            if clock.now < due { try? await Task.sleep(until: due, tolerance: .zero, clock: clock) }
            if clock.now - due > period { result.late += 1 }
            guard let point = target(index) else {
                result.missing += 1
                continue
            }
            let began = clock.now
            _ = move(to: point, areas: areas)
            result.moveMs.append((clock.now - began).inSeconds * 1_000)
            if landed(index) { result.landed += 1 }
        }
        _ = move(to: nil, areas: areas)
        result.seconds = (clock.now - start).inSeconds
        return result
    }
}
#endif
