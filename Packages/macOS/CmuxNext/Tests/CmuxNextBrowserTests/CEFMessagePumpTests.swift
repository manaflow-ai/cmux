import CmuxNextCompat
@testable import CmuxNextBrowser
@testable import CmuxNextWakeups
import Foundation
import Testing

/// The CEF pump's delayed fire dates on the main thread's one deadline queue: a
/// Chromium delayed task and the cmux deadlines near it share one wake (Chrome's one
/// `delayed_work_timer_` per thread, base/message_loop/message_pump_apple.mm), and the CEF pass runs
/// after the cmux entries of that fire in a run-loop block of its own, never inside the queue's fire.
/// The queue runs on a fake timer and uptime; the test drains the run-loop blocks by hand.
@MainActor
@Suite struct CEFMessagePumpTests {
    nonisolated private static let ms: UInt64 = 1_000_000

    @Test func aCEFRequestAt100MsAndADeadlineAt104MsShareOneFire() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        rig.queue.insert(owner: "DemandTimer", after: .milliseconds(104)) { rig.append("cmux") }
        #expect(rig.timer.armedDate == 104 * Self.ms, "100 ms snapped up to the 8 ms grid, where the 104 ms deadline is")
        rig.fire()
        #expect(rig.log == ["cmux"], "the queue's fire runs no CEF")
        #expect(rig.blocks == 1, "it queued one run-loop block for the CEF pass")
        rig.drain()
        #expect(rig.log == ["cmux", "pass"])
        #expect(rig.count(MainWakeUpQueue.ledgerOwner, reason: "fire") == 1, "one wake for both")
        #expect(rig.count("DemandTimer", reason: "deadline") == 1)
        #expect(rig.count(CEFMessagePump.ledgerOwner, reason: "now") == 1, "the start's pass")
        #expect(rig.count(CEFMessagePump.ledgerOwner, reason: "delayed") == 1, "CEF's 100 ms request")
        #expect(rig.records(of: CEFMessagePump.ledgerOwner) == 2, "one record per pump wake, no `deadline` beside it")
        #expect(rig.queue.count == 0)
    }

    /// A Chromium thread's request the gate kept fires at its own deadline, filed as `kept`.
    @Test func aKeptDeadlineFiresAsKeptOnTheQueue() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 10)
        #expect(!rig.pump.gate.admit(delayMilliseconds: 50, nowNanos: rig.uptime.now), "kept: the armed +10 ms comes first")
        rig.fire()
        rig.drain()
        #expect(rig.count(CEFMessagePump.ledgerOwner, reason: "delayed") == 1, "the +10 ms fire is CEF's own request")
        #expect(rig.queue.count == 1, "the pass armed the kept deadline")
        rig.fire()
        rig.drain()
        #expect(rig.uptime.now >= 50 * Self.ms)
        #expect(rig.count(CEFMessagePump.ledgerOwner, reason: "kept") == 1)
        #expect(rig.count(CEFMessagePump.ledgerOwner, reason: "delayed") == 1)
        #expect(rig.records(of: CEFMessagePump.ledgerOwner) == 3, "start, +10 ms, +50 ms: one record each")
        #expect(rig.log == ["pass", "pass"])
    }

    @Test func aNestedRunLoopInACEFPassDoesNotHoldACmuxDeadline() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        rig.queue.insert(owner: "sameFire", after: .milliseconds(104)) { rig.append("sameFire") }
        rig.queue.insert(owner: "later", after: .milliseconds(150)) { rig.append("later") }
        rig.onPass { [unowned rig] in
            rig.append("pass")
            #expect(rig.timer.armedDate == 152 * Self.ms, "the queue is armed for the next deadline while CEF runs")
            rig.fire() // a menu's tracking loop inside CefDoMessageLoopWork runs the queue's timer
            rig.append("pass end")
        }
        rig.fire()
        rig.drain()
        #expect(rig.log == ["sameFire", "pass", "later", "pass end"])
        #expect(rig.count(MainWakeUpQueue.ledgerOwner, reason: "fire") == 2)
    }

    @Test func aRequestForNowNeverWaitsForTheQueue() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        #expect(rig.queue.count == 1)
        rig.pump.scheduleNow()
        #expect(rig.blocks == 1, "queued for the next run loop pass at once")
        #expect(rig.queue.count == 0, "the block replaces the queue entry")
        rig.drain()
        #expect(rig.log == ["pass"])
        #expect(rig.count(MainWakeUpQueue.ledgerOwner, reason: "fire") == 0, "no queue wake")
        #expect(rig.queue.count == 1, "the 100 ms request is armed again after the pass")
    }

    @Test func repeatedNowRequestsQueueOneBlock() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.scheduleNow()
        rig.pump.scheduleNow()
        rig.pump.request(milliseconds: 0)
        #expect(rig.blocks == 1)
        rig.drain()
        #expect(rig.log == ["pass"])
    }

    @Test func aNewerRequestReplacesTheEntry() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        #expect(rig.timer.armedDate == 104 * Self.ms)
        rig.pump.request(milliseconds: 300)
        #expect(rig.queue.count == 1, "CEF's newer request replaces the older one")
        #expect(rig.timer.armedDate == 304 * Self.ms)
        rig.uptime.now = 150 * Self.ms
        rig.queue.fire()
        rig.drain()
        #expect(rig.log.isEmpty, "nothing is due at 150 ms")
        rig.fire()
        rig.drain()
        #expect(rig.log == ["pass"])
    }

    @Test func stopDropsTheEntryAndAQueuedBlock() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        rig.fire()
        #expect(rig.blocks == 1)
        rig.pump.stop()
        rig.drain()
        #expect(rig.log.isEmpty, "no CefDoMessageLoopWork after stop")
        rig.pump.request(milliseconds: 50)
        #expect(rig.queue.count == 0 && rig.blocks == 0)
    }

    @Test(arguments: [false, true])
    func aShortRequestIsArmedExactlyAtItsDelay(saver: Bool) {
        for delay: UInt64 in [1, 2, 16, 35] {
            let rig = PumpRig(saver: saver)
            rig.startAndRunFirstPass()
            rig.pump.request(milliseconds: Int64(delay))
            #expect(rig.timer.armedDate == delay * Self.ms, "a \(delay) ms request is exact (below 36 ms), saver \(saver)")
            #expect(rig.timer.armedTolerance == 0)
        }
    }

    @Test(arguments: [false, true])
    func aLongerRequestFiresWithinATenthOfItsDelayAndNeverEarly(saver: Bool) {
        for delay: UInt64 in [36, 50, 100, 1_000, 5_000] {
            let rig = PumpRig(saver: saver)
            rig.startAndRunFirstPass()
            rig.pump.request(milliseconds: Int64(delay))
            let deadline = delay * Self.ms
            let slack = min(8 * Self.ms, deadline / 10)
            let armed = rig.timer.armedDate ?? 0
            #expect(armed >= deadline && armed <= deadline + slack,
                    "\(delay) ms: armed \(armed) ns, saver \(saver); no whole-second or 32 ms grid")
            #expect(armed + rig.timer.armedTolerance <= deadline + slack, "the timer's tolerance stays in the window")
        }
    }

    /// A fork run time keeps Chromium's leeway on the queue: a flexible 7.9 ms
    /// request with 8 ms leeway fires in [7.9, 15.9] ms on its own 8 ms grid (not exact, as a
    /// whole-millisecond request under 36 ms is), a precise one exactly at 7.9 ms.
    @Test func anAbsoluteRequestKeepsChromiumsLeewayOnTheQueue() {
        let flexible = PumpRig()
        flexible.startAndRunFirstPass()
        flexible.pump.request(runTimeNanos: 7_900_000, leewayNanos: 8_000_000, precise: false)
        #expect(flexible.timer.armedDate == 8 * Self.ms, "the 8 ms boundary inside [7.9, 15.9] ms")
        let precise = PumpRig()
        precise.startAndRunFirstPass()
        precise.pump.request(runTimeNanos: 7_900_000, leewayNanos: 0, precise: true)
        let armed = precise.timer.armedDate ?? 0
        #expect(armed >= 7_899_999 && armed <= 7_900_000, "exact: \(armed) ns")
        #expect(precise.timer.armedTolerance == 0)
    }

    @Test func energySaverDoesNotMoveACEFRequest() {
        let rig = PumpRig(saver: true)
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        #expect(rig.timer.armedDate == 104 * Self.ms, "the pump's own 8 ms grid, not the saver's 32 ms")
    }

    @Test func aSameDeadlineReArmKeepsTheEntry() {
        let rig = PumpRig()
        rig.startAndRunFirstPass()
        rig.pump.request(milliseconds: 100)
        let arms = rig.timer.arms
        rig.pumpTimer.arm(after: 0.1, tolerance: 0.008)
        #expect(rig.timer.arms == arms, "no cancel and insert for the deadline already pending")
        #expect(rig.queue.count == 1)
    }
}

/// A pump on a `CEFWakeUpQueuePumpTimer` over a queue with a fake timer and uptime; the pump's clock
/// is the same uptime in seconds. Run-loop blocks wait until ``drain()``.
@MainActor
private final class PumpRig {
    /// What the test sees run, in order; a CEF pass logs "pass" unless ``onPass(_:)`` replaced it.
    final class Record {
        var lines: [String] = []
        var work: (() -> Void)?
        var blocks: [@MainActor () -> Void] = []
    }

    let timer = RecordingWakeUpTimer()
    let uptime = TestUptime()
    let ledger = WakeupLedger(uptime: { 0 })
    let queue: MainWakeUpQueue
    let pumpTimer: CEFWakeUpQueuePumpTimer
    let pump: CEFMessagePump
    private let record = Record()

    init(saver: Bool = false) {
        let timer = timer, uptime = uptime, record = record
        let energy = EnergyPolicySource(saver ? EnergyPolicy(saverReason: .setting) : .normal)
        queue = MainWakeUpQueue(energy: energy, ledger: ledger, uptime: { uptime.now }) { _ in timer }
        pumpTimer = CEFWakeUpQueuePumpTimer(queue: queue, uptime: { uptime.now }, post: { record.blocks.append($0) })
        pump = CEFMessagePump(
            work: {
                guard let work = record.work else { return record.lines.append("pass") }
                work()
            },
            timer: pumpTimer, clock: { Double(uptime.now) / 1e9 }, ledger: ledger
        )
    }

    var log: [String] { record.lines }
    /// Run-loop blocks queued and not yet run.
    var blocks: Int { record.blocks.count }

    func append(_ line: String) { record.lines.append(line) }

    /// Replaces what a CEF pass does.
    func onPass(_ work: @escaping () -> Void) { record.work = work }

    /// Starts the pump and runs the start's immediate pass, then clears the log.
    func startAndRunFirstPass() {
        pump.start()
        drain()
        record.lines.removeAll()
    }

    /// Moves the uptime to the queue's armed date and runs its fire, as the timer's callout does.
    func fire() {
        if let date = timer.armedDate { uptime.now = date }
        timer.fired()
        queue.fire()
    }

    /// Runs the queued run-loop blocks, and those they queue, in order.
    func drain() {
        while !record.blocks.isEmpty { record.blocks.removeFirst()() }
    }

    func count(_ owner: String, reason: String) -> UInt64 {
        ledger.snapshot().first { $0.owner == owner && $0.reason == reason }?.count ?? 0
    }

    /// Every ledger record of `owner`, whatever its reason.
    func records(of owner: String) -> UInt64 {
        ledger.snapshot().filter { $0.owner == owner }.reduce(0) { $0 + $1.count }
    }
}

/// The queue's timer: records each arm; the queue calls it with its own lock held, from any thread.
private nonisolated final class RecordingWakeUpTimer: MainWakeUpTimer, Sendable {
    private struct State {
        var arms: [UInt64] = []
        var armed: UInt64?
        var tolerance: UInt64 = 0
    }

    private let state = Mutex(State())

    var arms: [UInt64] { state.withLock { $0.arms } }
    var armedDate: UInt64? { state.withLock { $0.armed } }
    var armedTolerance: UInt64 { state.withLock { $0.tolerance } }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        state.withLock { state in
            state.arms.append(date)
            state.armed = date
            state.tolerance = tolerance
        }
    }

    func park() { state.withLock { $0.armed = nil } }

    /// CFRunLoop parks the repeating timer after its callout.
    func fired() { state.withLock { $0.armed = nil } }
}

/// The rig's uptime in ns: the queue reads it from any thread, the test's main actor moves it.
private nonisolated final class TestUptime: Sendable {
    private let value = Atomic<UInt64>(0)

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
