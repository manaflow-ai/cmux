public import CmuxNextWakeups
import Foundation

/// The app's one main-thread scheduler on display frames the test fires (``tick()``), with a board
/// whose ledger folds only when read: a test counts the main-thread tasks each owner ran from the
/// scheduler's own records (``tasks(of:)``), as `debug.main_budget` reads them. Posts made off main
/// arrive on the main run loop (``runTurns(until:)``). The budget's clock moves one frame per tick
/// and never inside one, so no class runs out of budget.
///
/// ```swift
/// let frames = ManualMainFrames()
/// let wake = FrameOutboxWake.nextFrame(owner: "pages.events", on: frames.work)
/// frames.runTurns { frames.tasks(of: "pages.events") == 1 }
/// frames.tick()
/// ```
@MainActor
public final class ManualMainFrames {
    /// The scheduler: off-main posts reach it on the main run loop, its frames come on ``tick()``.
    public let work: MainWorkScheduler
    private let uptime: Uptime
    private var frame = 0.0

    public init() {
        let uptime = Uptime()
        self.uptime = uptime
        let board = MainTaskBoard(ledger: MainOwnerLedger(capacity: 1 << 14, folding: .manual))
        work = .testing(budget: MainFrameBudget(board: board, uptimeNanos: { uptime.nanos }), clock: ManualClock(),
                        ledger: WakeupLedger()) { _ in ManualFrameLink() }
    }

    /// Fires one display frame, a 60 Hz vsync after the last.
    public func tick() {
        frame += 1
        uptime.nanos += 16_666_667
        work.frameDidFire(timestamp: frame, refreshInterval: 1.0 / 60)
    }

    /// Runs main run loop turns, where posts made off main arrive, until `done` or 5 s pass.
    ///
    /// - Returns: Whether `done` came.
    @discardableResult
    public func runTurns(until done: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: 5)
        while !done() {
            guard Date() < end else { return false }
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
        }
        return true
    }

    /// Runs the main run loop for about 2 ms: the turns between two frames, where posts made off main
    /// arrive. Synchronous, because `RunLoop.run` is unavailable from async contexts.
    public func runTurnsBetweenFrames() {
        _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
    }

    /// The main-thread tasks `owner` ran so far, every class, from the board's ledger.
    public func tasks(of owner: String) -> Int {
        work.board.ownerSnapshot().owners.filter { $0.owner == owner }.reduce(0) { $0 + $1.tasks }
    }
}

/// The budget's clock, in `CLOCK_UPTIME_RAW` nanoseconds; ``ManualMainFrames/tick()`` moves it.
@MainActor
private final class Uptime {
    var nanos: UInt64 = 1_000_000_000
}

/// A display link that never fires by itself: the test's ticks are the frames.
@MainActor
private final class ManualFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
