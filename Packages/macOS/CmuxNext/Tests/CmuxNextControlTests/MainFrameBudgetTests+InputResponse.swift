import CmuxNextCompat
import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Testing

/// The input-response state and the typing-burst rate of ``MainFrameBudget``:
/// a discrete input that expects a frame holds automation and background until the next
/// link tick has rendered (at most 100 ms), and while a person types they run one task per 100 ms.
extension MainFrameBudgetTests {
    @Test func aKeyThatExpectsNoFrameOpensNoInputResponse() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: false)
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.mayRun(.background))
        #expect(budget.stats.yieldedToInputResponse == [0, 0, 0, 0])
    }

    @Test func automationWaitsForTheNextTicksRenderNotTheKeysOwnCommit() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(!budget.mayRun(.automation))
        #expect(!budget.mayRun(.background))
        // The key's own turn commits (its CommitBoundary) before any tick of the link.
        budget.noteTickRenderEnded()
        #expect(budget.isInputResponseOpen, "the key's own commit does not close it")
        #expect(!budget.mayRun(.automation))
        clock.advance(nanos: ResponseClock.frame)
        budget.beginFrame(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(!budget.mayRun(.automation), "the tick after the key has not rendered yet")
        budget.noteTickRenderEnded()
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.mayRun(.background))
        #expect(budget.stats.yieldedToInputResponse == [0, 2, 1, 0], "counted once per class and frame")
        #expect(budget.stats.maxInputResponseNanos == ResponseClock.frame)
        #expect(budget.stats.inputResponseCapHits == 0)
    }

    @Test func aUserBlockingCommitClosesTheInputResponse() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        clock.advance(nanos: 3_000_000)
        budget.noteUserBlockingCommit()
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.maxInputResponseNanos == 3_000_000)
    }

    @Test func anInputResponseWithNoRenderClosesAt100Milliseconds() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteDiscreteInput(expectsFrame: true)
        clock.advance(nanos: 50_000_000)
        #expect(budget.isInputResponseOpen)
        #expect(!budget.mayRun(.automation))
        clock.advance(nanos: 50_000_000)
        #expect(!budget.isInputResponseOpen)
        #expect(budget.mayRun(.automation))
        #expect(budget.stats.inputResponseCapHits == 1)
        #expect(budget.stats.maxInputResponseNanos == 100_000_000)
    }

    @Test func anInputResponseHoldsNeitherFrameWorkNorVisibleUpdates() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        var order: [String] = []
        let automation = FrameClient(owner: "automation", budgeted: .automation, on: scheduler) { _, budget in
            budget.run(.automation, owner: budget.board.owner("automation")) { order.append("automation") }
            return true
        }
        let visible = FrameClient(owner: "visible", budgeted: .visible, on: scheduler) { _, budget in
            budget.run(.visible, owner: budget.board.owner("visible")) { order.append("visible") }
            return true
        }
        let spring = FrameClient(owner: "spring", on: scheduler.frames) { _ in order.append("frame"); return true }
        for client in [automation, visible, spring] { client.activate() }
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(budget.mayRun(.input))
        #expect(budget.mayRun(.frame))
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "visible"], "the input response holds automation only")
        budget.noteTickRenderEnded()
        order.removeAll()
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(order == ["frame", "visible", "automation"])
        for client in [automation, visible, spring] { client.deactivate() }
    }

    /// Keys at 30 a second, each expecting a frame, against a queue of agent requests: the requests
    /// start at most ten a second, never more than 100 ms plus a frame apart, and never inside an
    /// open input response; once typing stops for 500 ms the frame's budget applies again.
    @Test func keysAt30PerSecondGiveAutomationOneTaskPer100Milliseconds() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        let run = typeKeys(every: 33_333_333, clock: clock, budget: budget, scheduler: scheduler)
        let typed = run.starts.filter { $0 < run.start + 1_500_000_000 }
        #expect(typed.count >= 14)
        for (earlier, later) in zip(typed, typed.dropFirst()) {
            #expect(later - earlier <= Self.burstGap, "automation waited \(later - earlier) ns")
        }
        for index in typed.indices.dropLast(10) {
            #expect(typed[index + 10] - typed[index] >= 1_000_000_000, "more than ten requests in one second")
        }
        #expect(run.insideResponse == 0, "a request ran inside the person's input response")
        // Typing stopped 500 ms ago: the frame's budget applies, many requests a frame.
        let before = run.starts.count
        clock.set(run.start + 2_100_000_000)
        scheduler.frameDidFire(timestamp: 200, refreshInterval: 1.0 / 60)
        #expect(run.starts.count - before > 1)
    }

    /// A frame-expecting key every frame keeps a response open at every tick: a due request waits
    /// one frame for it, then runs, so requests still start once per 100 ms plus a frame.
    @Test func aKeyEveryFrameHoldsADueRequestOneFrameOnly() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        let run = typeKeys(every: ResponseClock.frame, clock: clock, budget: budget, scheduler: scheduler)
        let typed = run.starts.filter { $0 < run.start + 1_500_000_000 }
        #expect(typed.count >= 12)
        #expect((typed.first ?? .max) - run.start <= Self.burstGap, "the first request waited past 100 ms and a frame")
        for (earlier, later) in zip(typed, typed.dropFirst()) {
            #expect(later - earlier >= Self.burstInterval, "two requests less than 100 ms apart")
            #expect(later - earlier <= Self.burstGap, "automation waited \(later - earlier) ns")
        }
        #expect(budget.stats.yieldedToInputResponse[1] > 0)
    }

    /// Starts between ticks (an idle queue's request, a posted turn) keep both bounds: never two
    /// within 100 ms, so never 11 in a second, and never more than 100 ms plus the call spacing apart.
    @Test func offTickStartsKeepTheTypingBurstRate() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let owner = budget.board.owner("posted")
        let start = clock.now
        var starts: [UInt64] = []
        var nextKey = start
        while clock.now < start + 1_500_000_000 {
            if clock.now >= nextKey {
                budget.noteDiscreteInput(expectsFrame: false)
                nextKey += 33_333_333
            }
            if budget.mayRun(.automation) { budget.run(.automation, owner: owner) { starts.append(clock.now) } }
            clock.advance(nanos: 7_000_000)
        }
        #expect(starts.count >= 14)
        for (earlier, later) in zip(starts, starts.dropFirst()) {
            #expect(later - earlier >= Self.burstInterval, "two requests less than 100 ms apart")
            #expect(later - earlier <= Self.burstInterval + 7_000_000)
        }
        #expect(budget.stats.waitedForBurstSlot[1] > 0)
    }

    /// A drain that ran no request (its queue was empty, or its first request yielded) takes no
    /// typing-burst slot: the next request still runs when it is due.
    @Test func aBatchThatRanNoRequestTakesNoBurstSlot() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.noteDiscreteInput(expectsFrame: false)
        clock.advance(nanos: Self.burstInterval)
        budget.beginFrame(timestamp: 1, refreshInterval: 1.0 / 60)
        #expect(budget.mayRun(.automation))
        budget.run(.automation, owner: budget.board.owner("Control.frames")) {
            budget.markRunningTaskAsBatch()
            clock.advance(nanos: 50_000)
        }
        #expect(budget.mayRun(.automation), "the empty drain took the slot")
        budget.run(.automation, owner: budget.board.owner("workspace.move")) {}
        #expect(!budget.mayRun(.automation), "the request took it")
    }

    /// A response nothing closed before the cap closes as capped, whatever closes it later.
    @Test func aUserBlockingCommitPastTheCapCountsACapHit() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        budget.noteDiscreteInput(expectsFrame: true)
        clock.advance(nanos: 150_000_000)
        budget.noteUserBlockingCommit()
        #expect(budget.stats.inputResponseCapHits == 1)
        #expect(budget.stats.maxInputResponseNanos == Self.responseCap)
    }

    /// With no budgeted work queued, the link is idle; the key's response asks it for one tick, so
    /// the response closes at the key's next frame (a measured render pass), not at the cap.
    @Test func aKeyWithNoBudgetedWorkClosesAtItsNextFrame() {
        let clock = ResponseClock()
        let budget = MainFrameBudget(uptimeNanos: clock.read)
        let scheduler = MainWorkScheduler.testing(budget: budget) { _ in ResponseFrameLink() }
        #expect(!scheduler.frames.hasLink)
        budget.noteDiscreteInput(expectsFrame: true)
        #expect(scheduler.frames.hasLink, "the open response asked for a tick")
        budget.noteRenderPass(nanos: 1_000_000) // the key's own turn
        #expect(budget.isInputResponseOpen)
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 1, refreshInterval: 1.0 / 60)
        budget.noteRenderPass(nanos: 1_000_000) // the tick's pass
        #expect(!budget.isInputResponseOpen)
        #expect(budget.stats.inputResponseCapHits == 0)
        #expect(budget.stats.maxInputResponseNanos == ResponseClock.frame)
        clock.advance(nanos: ResponseClock.frame)
        scheduler.frameDidFire(timestamp: 2, refreshInterval: 1.0 / 60)
        #expect(!scheduler.frames.hasLink, "the link goes idle again")
    }

    /// In a typing burst the automation rate holds the next request for 100 ms; an injected key
    /// that waited behind its connection's request is input, not automation, so it runs in the
    /// same drain right after that request.
    @Test func anInjectedKeyBehindARequestRunsInTheSameFrameDuringABurst() async {
        let budget = MainFrameBudget()
        let frames = BurstFrameSource(budget: budget)
        let queue = MainActorWorkQueue(frameSource: frames)
        let deadline = ContinuousClock.now + .seconds(20)
        let order = Recorder()
        let client = ControlConnectionID(rawValue: 5)
        budget.noteDiscreteInput(expectsFrame: false)
        let focus = Task.detached {
            try await queue.run(connection: client, method: "surface.focus", deadline: deadline) { order.append("focus") }
        }
        while queue.stats.pending < 1 { await Task.yield() }
        let key = Task.detached {
            try await queue.run(connection: client, method: "debug.key", workClass: .input, deadline: deadline) { order.append("key") }
        }
        while queue.stats.pending < 2 { await Task.yield() }
        frames.fire()
        #expect(order.names == ["focus", "key"], "the key waited for the automation rate")
        #expect(budget.board.pendingInputCount == 0)
        _ = try? await focus.value
        _ = try? await key.value
    }

    /// Keys every `keyInterval` for 1.5 s, each expecting a frame and committing in its own turn,
    /// against 400 queued agent requests on the budgeted link; each tick renders after its batches.
    private func typeKeys(every keyInterval: UInt64, clock: ResponseClock, budget: MainFrameBudget,
                          scheduler: MainWorkScheduler) -> TypedRun {
        let requests = FrameBatchQueue(owner: "Control.frames", budgeted: .automation, on: scheduler)
        let run = TypedRun(start: clock.now)
        for _ in 0..<400 {
            requests.enqueue {
                run.starts.append(clock.now)
                if budget.isInputResponseOpen { run.insideResponse += 1 }
                clock.advance(nanos: 100_000)
            }
        }
        var nextKey = run.start
        for frame in 0..<90 {
            let tickTime = run.start + UInt64(frame) * ResponseClock.frame
            while nextKey <= tickTime, nextKey < run.start + 1_500_000_000 {
                clock.set(max(nextKey, clock.now))
                budget.noteDiscreteInput(expectsFrame: true)
                budget.noteTickRenderEnded() // the key's own commit
                nextKey += keyInterval
            }
            clock.set(tickTime)
            scheduler.frameDidFire(timestamp: Double(frame + 1), refreshInterval: 1.0 / 60)
            budget.noteTickRenderEnded()
        }
        return run
    }

    /// The typing burst's interval and the input response's cap, as the spec states them.
    private static let burstInterval: UInt64 = 100_000_000
    private static let responseCap: UInt64 = 100_000_000
    /// The longest gap between two automation tasks in a typing burst: the interval plus one frame
    /// (an open response holds a due task one frame), plus clock rounding.
    private static let burstGap: UInt64 = 100_000_000 + 16_666_667 + 1_000
}

/// What ``MainFrameBudgetTests/typeKeys(every:clock:budget:scheduler:)`` saw.
@MainActor
private final class TypedRun {
    let start: UInt64
    var starts: [UInt64] = []
    var insideResponse = 0
    init(start: UInt64) { self.start = start }
}

/// The names of the requests that ran, in order (a Sendable class can own the `Mutex` that a
/// detached task's closure cannot capture as a local).
private final class Recorder: Sendable {
    private let mutex = Mutex<[String]>([])
    nonisolated deinit {}
    var names: [String] { mutex.withLock { $0 } }
    func append(_ name: String) { mutex.withLock { $0.append(name) } }
}

/// A frame source with the app's budget whose frames fire by hand, each as one automation batch
/// (as the app's control `FrameBatcher` runs them).
private final class BurstFrameSource: ControlFrameSource {
    private let frames = ManualFrameSource()
    nonisolated(unsafe) private let budgetRef: MainFrameBudget // crash-allow: read only on the main actor (mainFrameBudget, fire)
    let mainTaskBoard: MainTaskBoard?
    private let tick = Mutex<Double>(0)

    @MainActor init(budget: MainFrameBudget) {
        budgetRef = budget
        mainTaskBoard = budget.board
    }

    @MainActor var mainFrameBudget: MainFrameBudget? { budgetRef }

    func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) { frames.scheduleFrame(work) }

    @MainActor func fire() {
        let timestamp = tick.withLock { $0 += 1; return $0 }
        budgetRef.beginFrame(timestamp: timestamp, refreshInterval: 1.0 / 60)
        budgetRef.run(.automation, owner: budgetRef.board.owner("Control.frames")) { frames.fire() }
    }
}

/// A clock the test moves (`CLOCK_UPTIME_RAW` nanoseconds).
@MainActor
private final class ResponseClock {
    /// One 60 Hz frame.
    static let frame: UInt64 = 16_666_667
    private(set) var now: UInt64 = 1_000_000_000
    var read: () -> UInt64 { { [self] in self.now } }
    func advance(nanos: UInt64) { now += nanos }
    func set(_ value: UInt64) { now = value }
}

@MainActor
private final class ResponseFrameLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
