import CmuxNextWakeups
import QuartzCore

/// DIAG ONLY (RESIZE P0 17, a -nomerge branch, never lands): `debug.frames`' record of every main run-loop turn while
/// it runs: [woke ms, turn ms, main work ms (to the commit), window layout passes, view layouts, tags
/// (WakeupLedger+TurnTrace: "name count us;...")], and each frame tick's arrival; ms from the probe's start.
struct MainTurnLog {
    static let capacity = 60_000
    private var turns: [[Any]] = []
    private var ticks: [Double] = []
    private var origin: CFTimeInterval = 0
    private var counts = (view: 0, window: 0)

init() {}

mutating func reset(origin: CFTimeInterval) {
        turns.removeAll(keepingCapacity: true)
        ticks.removeAll(keepingCapacity: true)
        self.origin = origin
        counts = (LayoutPassGuard.shared.viewLayoutCalls, LayoutPassGuard.shared.windowLayoutPasses)
        _ = WakeupLedger.shared.takeTurnTags()
    }

    /// The main run loop woke.
mutating func woke() {
        counts = (LayoutPassGuard.shared.viewLayoutCalls, LayoutPassGuard.shared.windowLayoutPasses)
    }

    /// The main run loop goes to sleep: the turn's record.
mutating func ended(woke: CFTimeInterval, mainEnd: CFTimeInterval?, end: CFTimeInterval) {
        let guardian = LayoutPassGuard.shared
        let tags = WakeupLedger.shared.takeTurnTags()
        defer { counts = (guardian.viewLayoutCalls, guardian.windowLayoutPasses) }
        guard turns.count < Self.capacity, origin > 0 else { return }
        turns.append([ms(woke - origin), ms(end - woke), ms((mainEnd ?? end) - woke),
                      guardian.windowLayoutPasses &- counts.window, guardian.viewLayoutCalls &- counts.view, tags])
    }

    /// A frame tick ran on main at `now`.
mutating func ticked(at now: CFTimeInterval) {
        if ticks.count < Self.capacity { ticks.append(ms(now - origin)) }
    }

var report: [String: Any] { ["turns": turns, "tick_ms": ticks] }

    private func ms(_ seconds: CFTimeInterval) -> Double { (seconds * 1_000_000).rounded() / 1_000 }
}
