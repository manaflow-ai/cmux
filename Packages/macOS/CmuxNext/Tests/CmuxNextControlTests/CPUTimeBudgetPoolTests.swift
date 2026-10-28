import CmuxNextWakeups
import Foundation
import Testing

/// The CPU-time budget of hidden nodes' main-thread work (plans/cmux-next/chrome-parity/
/// p06-scheduler.md): 10 ms/s refill, 100 ms cap, visible and exempt work free, and
/// MainTaskQueue's hidden background work charged to the scheduler's one pool.
@MainActor @Suite(.timeLimit(.minutes(1))) struct CPUTimeBudgetPoolTests {
    private static let ms: UInt64 = 1_000_000
    private static let second: UInt64 = 1_000_000_000

    @Test func twentyMillisecondsPerFireIsHeldToTenMillisecondsPerSecond() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        var runs: [Int] = []
        // A hidden repeating timer on 1 s-aligned wakes, 20 ms of work per fire, for 200 s.
        for wake in 0 ..< 200 {
            clock.now = clock.origin + UInt64(wake) * Self.second
            guard pool.mayRun(.hidden) else { continue }
            pool.run(.hidden) { clock.now += 20 * Self.ms }
            runs.append(wake)
        }
        // The full 100 ms balance pays for the first 10 fires; after that every second wake has budget.
        #expect(Array(runs.prefix(10)) == Array(0 ..< 10))
        #expect(runs.filter { $0 >= 100 }.count == 50, "steady state: 20 ms every 2 s is 10 ms/s")
        let charged = pool.stats.charged
        #expect(charged <= .milliseconds(100 + 10 * 200 + 20), "never more than the cap plus 10 ms/s plus one fire")
        #expect(charged >= .milliseconds(10 * 200 - 20))
        #expect(pool.stats.hiddenRuns == runs.count)
    }

    @Test func aNegativeBalanceWaitsForTheRefillToZero() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .milliseconds(120))
        #expect(pool.balance == .milliseconds(-20))
        #expect(!pool.mayRun(.hidden))
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(2), "20 ms at 10 ms/s")
        clock.now += Self.second
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(1))
        clock.now += Self.second
        #expect(pool.delayUntilAllowed(.hidden) == .zero)
        #expect(pool.mayRun(.hidden), "a zero balance runs (Blink: the next allowed time is now)")
    }

    @Test func theBalanceRefillsUpToTheCapOnly() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        #expect(pool.balance == .milliseconds(100), "a new pool starts full")
        pool.record(.hidden, ran: .milliseconds(60))
        clock.now += 3 * Self.second
        #expect(pool.balance == .milliseconds(70))
        clock.now += 3600 * Self.second
        #expect(pool.balance == .milliseconds(100), "an hour hidden and idle still allows only 100 ms at once")
    }

    @Test func oneLongTaskHoldsHiddenWorkBackForTheMaxDelayAtMost() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .seconds(600))
        #expect(pool.balance == .milliseconds(-600), "the floor is what refills in 60 s")
        #expect(pool.delayUntilAllowed(.hidden) == .seconds(60))
    }

    @Test func visibleWorkIsNeverChargedAndNeverWaits() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        for _ in 0 ..< 1000 {
            #expect(pool.mayRun(.visible))
            pool.run(.visible) { clock.now += 20 * Self.ms }
        }
        pool.record(.visible, ran: .seconds(5))
        #expect(pool.balance == .milliseconds(100))
        #expect(pool.stats == CPUTimeBudgetPool.Stats())
        #expect(pool.mayRun(.hidden), "visible work leaves the hidden budget untouched")
    }

    @Test func exemptWorkIsNeverDeferredOrCharged() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        pool.record(.hidden, ran: .milliseconds(300))
        #expect(!pool.mayRun(.hidden))
        let before = pool.balance
        for _ in 0 ..< 100 {
            #expect(pool.delayUntilAllowed(.exempt) == .zero, "media or a capture vote is never deferred")
            pool.run(.exempt) { clock.now += 20 * Self.ms }
        }
        // 2 s passed in the exempt runs: only the refill moved the balance.
        #expect(pool.balance == before + .milliseconds(20))
        #expect(pool.stats.hiddenRuns == 1)
    }

    @Test func theChargeFollowsTheNodeState() {
        #expect(CPUTimeBudgetPool.Charge(isVisible: true, mediaOrCapture: false) == .visible)
        #expect(CPUTimeBudgetPool.Charge(isVisible: true, mediaOrCapture: true) == .visible)
        #expect(CPUTimeBudgetPool.Charge(isVisible: false, mediaOrCapture: true) == .exempt)
        #expect(CPUTimeBudgetPool.Charge(isVisible: false, mediaOrCapture: false) == .hidden)
    }

    @Test func aRunThatThrowsIsStillCharged() {
        let clock = PoolClock()
        let pool = CPUTimeBudgetPool(uptimeNanos: clock.read)
        #expect(throws: PoolProbeError.self) {
            try pool.run(.hidden) {
                clock.now += 30 * Self.ms
                throw PoolProbeError()
            }
        }
        #expect(pool.balance == .milliseconds(70))
    }

    // MARK: MainTaskQueue

    /// A hidden node's background queue, one 20 ms task posted each second and its hidden wake fired at
    /// each second: the scheduler's pool holds it to 10 ms/s, and a wake in debt runs nothing.
    @Test func aHiddenQueueIsHeldToTenMillisecondsPerSecond() {
        let rig = PoolQueueRig()
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let queue = tab.queue(.background, owner: "Tab.snapshot", on: rig.work)
        var runs = 0
        for second in 0 ..< 200 {
            rig.clock.now = max(rig.clock.now, rig.clock.origin + UInt64(second) * Self.second)
            queue.post(key: "snapshot") { [clock = rig.clock] in
                clock.now += 20 * Self.ms
                runs += 1
            }
            rig.fireWakes()
            rig.frames(1)
        }
        let pool = rig.work.hiddenBudget
        #expect(pool.stats.hiddenRuns == runs)
        #expect(pool.stats.charged == .milliseconds(20 * runs))
        #expect(pool.stats.charged <= .milliseconds(100 + 10 * 200 + 20), "never more than the cap plus 10 ms/s plus one task")
        #expect(runs >= 90 && runs <= 106, "20 ms tasks fit about once each 2 s: \(runs)")
        #expect(queue.runCount(whileNode: .hidden) == runs)
        rig.stop()
    }

    @Test func visibleQueueWorkIsNeverCharged() {
        let rig = PoolQueueRig()
        rig.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let before = rig.work.hiddenBudget.stats
        let window = VisibilityNode(root: "window", own: .visible)
        let queue = window.queue(.visible, owner: "Tab.title", on: rig.work)
        let background = window.queue(.background, owner: "Tab.persist", on: rig.work)
        var runs = 0
        for _ in 0 ..< 50 {
            queue.post { [clock = rig.clock] in clock.now += 2 * Self.ms; runs += 1 }
            background.post { [clock = rig.clock] in clock.now += 2 * Self.ms; runs += 1 }
        }
        rig.frames(100)
        #expect(runs == 100, "a visible node's work never waits for the hidden budget")
        #expect(rig.work.hiddenBudget.stats == before, "visible work is never charged")
        rig.stop()
    }

    /// A hidden node with media playing, or held by a capture vote that keeps it hidden, runs its
    /// background work at once with the budget spent, asks for no wake and is not charged.
    @Test func exemptNodesAreNeverDeferred() {
        let rig = PoolQueueRig()
        rig.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let before = rig.work.hiddenBudget.stats
        let window = VisibilityNode(root: "window", own: .visible)
        let media = VisibilityNode("media", own: .hidden, parent: window)
        let captured = VisibilityNode("captured", own: .hidden, parent: window)
        media.setMediaActive(true)
        let vote = captured.captureVote(reason: "test.screencast", stayHidden: true)
        let mediaQueue = media.queue(.background, owner: "Media.persist", on: rig.work)
        let capturedQueue = captured.queue(.background, owner: "Capture.persist", on: rig.work)
        var ran: [String] = []
        for _ in 0 ..< 5 {
            mediaQueue.post { [clock = rig.clock] in clock.now += 2 * Self.ms; ran.append("media") }
            capturedQueue.post { [clock = rig.clock] in clock.now += 2 * Self.ms; ran.append("captured") }
        }
        rig.frames(20)
        #expect(ran.count == 10, "exempt work ran with no wake and the budget spent")
        #expect(rig.wakes.isEmpty, "an exempt node asks for no hidden wake")
        #expect(rig.work.hiddenBudget.stats == before, "exempt work is never charged")
        #expect(CPUTimeBudgetPool.Charge(of: media) == .exempt && CPUTimeBudgetPool.Charge(of: captured) == .exempt)
        vote.release()
        rig.stop()
    }

    /// Media starting on a node whose background work waits for budget runs that work at once.
    @Test func mediaStartingReleasesWorkHeldForBudget() {
        let rig = PoolQueueRig()
        rig.work.hiddenBudget.record(.hidden, ran: .seconds(1))
        let window = VisibilityNode(root: "window", own: .visible)
        let tab = VisibilityNode("tab", own: .hidden, parent: window)
        let queue = tab.queue(.background, owner: "Tab.persist", on: rig.work)
        var runs = 0
        queue.post { runs += 1 }
        rig.fireWakes()
        rig.frames(2)
        #expect(runs == 0 && queue.isHolding, "a wake in debt runs nothing")
        #expect(rig.wakes.count == 1, "and asks for the next wake")
        tab.setMediaActive(true)
        rig.frames(1)
        #expect(runs == 1)
        rig.stop()
    }
}

private struct PoolProbeError: Error {}

/// A main-thread scheduler whose posts run at hand-fired frames, on a clock the test moves (the
/// budget's clock, so the hidden budget's too), with the hidden wakes kept for the test to fire.
@MainActor
private final class PoolQueueRig {
    let work: MainWorkScheduler
    let clock: PoolClock
    private(set) var wakes: [@MainActor () -> Void] = []
    private var timestamp: Double = 1
    private let keeper: FrameClient

    init() {
        let clock = PoolClock()
        self.clock = clock
        work = MainWorkScheduler.testing(budget: MainFrameBudget(uptimeNanos: clock.read)) { _ in PoolFakeLink() }
        keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        keeper.activate()
        work.hiddenWake = { [weak self] _, wake in self?.wakes.append(wake) }
    }

    /// Fires the hidden wakes asked for so far; one asked for while they run waits for the next call.
    func fireWakes() {
        let due = wakes
        wakes.removeAll()
        for wake in due { wake() }
    }

    /// Fires `count` frames, 17 ms apart.
    func frames(_ count: Int) {
        for _ in 0 ..< count {
            clock.now += 17_000_000
            timestamp += 1.0 / 60
            work.frameDidFire(timestamp: timestamp, refreshInterval: 1.0 / 60)
        }
    }

    func stop() { keeper.deactivate() }
}

@MainActor
private final class PoolFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}

@MainActor
private final class PoolClock {
    let origin: UInt64 = 1_000_000_000
    var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
}
