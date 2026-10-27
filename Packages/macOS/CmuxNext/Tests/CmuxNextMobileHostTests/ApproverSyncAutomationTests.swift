import CmuxNextAgentPane
import CmuxNextCompat
@testable import CmuxNextMobileHost
@testable import CmuxNextWakeups
import Foundation
import Testing

/// p06-scheduler-342 (p06-scheduler.md rule 9, the automation class): the iPhone approvers' reconnect is an
/// automation ``MainDeadline`` on the app's scheduler, not a Task's sleep, so the connect it runs yields to a
/// person's pending input: it runs on a frame after the input, never ahead of it.
@MainActor @Suite(.serialized)
struct ApproverSyncAutomationTests {
    @Test func theReconnectYieldsToThePersonsPendingInput() {
        let rig = ApproverSyncRig()
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("approvers-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let environment = AcpmuxEnvironment(executable: URL(fileURLWithPath: "/usr/bin/false"), home: home,
                                            socketPath: home.appendingPathComponent("acpmux.sock").path,
                                            daemonArguments: [], childEnvironment: [:])
        let sync = MobileHostApproverSync(environment: environment, deadlines: rig.deadlines)
        sync.update(["approvers": ["phone-key"]])
        #expect(sync.connectAttempts == 1, "a first approver list did not try to connect")
        #expect(rig.hasArmedWake, "an absent socket armed no reconnect")

        rig.input.pending = true
        rig.fireAndRun()
        #expect(sync.connectAttempts == 1, "the reconnect ran ahead of the person's pending input")
        rig.input.pending = false
        rig.frame()
        #expect(sync.connectAttempts == 2, "the reconnect never ran once the input was handled")
        sync.stop()
    }
}

/// The app's deadline scheduler on a wake-up queue the test fires, at a fake uptime, with an input source the test
/// sets and posted work run by hand-fired frames (CmuxNextAppTests' MainDeadlineRig, with an input source).
@MainActor
private final class ApproverSyncRig {
    let deadlines: MainDeadlineScheduler
    let input: ApproverSyncInput
    private let timer: HandFiredWakeUpTimer
    private let uptime: RigUptime
    private let queue: MainWakeUpQueue
    private let work: MainWorkScheduler
    private let budgetClock: RigUptime
    private let keeper: FrameClient
    private var frames: Double = 0

    init() {
        let timer = HandFiredWakeUpTimer(), uptime = RigUptime(0), budgetClock = RigUptime(1_000_000_000), input = ApproverSyncInput()
        self.input = input
        self.timer = timer
        self.uptime = uptime
        self.budgetClock = budgetClock
        let queue = MainWakeUpQueue(energy: EnergyPolicySource(), ledger: WakeupLedger(uptime: { 0 }), uptime: { uptime.now }) { _ in timer }
        let work = MainWorkScheduler.testing(budget: MainFrameBudget(input: input, uptimeNanos: { budgetClock.now }),
                                             ledger: WakeupLedger()) { _ in ApproverSyncLink() }
        self.queue = queue
        self.work = work
        deadlines = MainDeadlineScheduler(work: work, queue: queue)
        let keeper = FrameClient(owner: "test.keeper", isAnimation: false, on: work.frames) { _ in true }
        self.keeper = keeper
        keeper.activate()
    }

    /// Whether a wake is armed (a pending deadline).
    var hasArmedWake: Bool { timer.armedDate != nil }

    /// Moves the uptime to the armed wake, fires the queue and runs the posted actions in one frame.
    func fireAndRun() {
        if let date = timer.armedDate { uptime.now = max(uptime.now, date) }
        timer.armedDate = nil
        queue.fire()
        frame()
    }

    /// One display frame with no wake: runs the posted work only.
    func frame() {
        budgetClock.now += 17_000_000
        frames += 1
        work.frameDidFire(timestamp: frames, refreshInterval: 1.0 / 60)
    }
}

/// The person's input, pending or not, as the test sets it.
@MainActor
private final class ApproverSyncInput: InputPendingSource {
    var pending = false
    func hasPendingInput(uptime: TimeInterval) -> Bool { pending }
}

/// Keeps the date the queue armed; the test fires the queue itself.
private nonisolated final class HandFiredWakeUpTimer: MainWakeUpTimer, Sendable {
    private let armed = Mutex<UInt64?>(nil)

    var armedDate: UInt64? {
        get { armed.withLock { $0 } }
        set { armed.withLock { $0 = newValue } }
    }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) { armedDate = date }
    func park() { armedDate = nil }
}

/// A fake clock in ns: the queue reads it from any thread, only the test's main actor moves it.
private nonisolated final class RigUptime: Sendable {
    private let value: Atomic<UInt64>

    init(_ start: UInt64) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}

private final class ApproverSyncLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
