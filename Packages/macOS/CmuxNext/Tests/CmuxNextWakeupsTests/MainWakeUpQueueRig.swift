import CmuxNextCompat
@testable import CmuxNextWakeups

/// A MainWakeUpQueue with a fake timer, a fake uptime and its own ledger, shared by the suites that drive
/// the queue (MainWakeUpQueueTests, AlignedWakeupsTests). The test fires the timer itself.
@MainActor
struct WakeUpQueueRig {
    let timer = FakeWakeUpTimer()
    let uptime: FakeUptime
    let ledger = WakeupLedger(uptime: { 0 })
    let queue: MainWakeUpQueue

    /// - Parameters:
    ///   - energy: The policy whose `wakeAlignment` is the sub-second grid (default: the saver off, 8 ms).
    ///   - start: The fake uptime's start, in ns.
    init(energy: EnergyPolicySource = EnergyPolicySource(), start: UInt64 = 0) {
        let timer = timer, uptime = FakeUptime(start)
        self.uptime = uptime
        queue = MainWakeUpQueue(energy: energy, ledger: ledger, uptime: { uptime.now }) { _ in timer }
    }

    /// Moves the uptime to the armed date and runs the timer's callout.
    func fire() {
        if let date = timer.armedDate { uptime.now = date }
        timer.fired()
        queue.fire()
    }

    /// The queue's wakes.
    var fires: UInt64 { count(MainWakeUpQueue.ledgerOwner, reason: "fire") }
    func deadlines(of owner: String) -> UInt64 { count(owner, reason: "deadline") }

    private func count(_ owner: String, reason: String) -> UInt64 {
        ledger.snapshot().first { $0.owner == owner && $0.reason == reason }?.count ?? 0
    }
}

/// Records each arm and park. The queue calls it from the inserting threads and the test reads it on the
/// main actor, so the record is behind its own lock.
final class FakeWakeUpTimer: MainWakeUpTimer, Sendable {
    struct Arm: Equatable, Sendable {
        var date: UInt64
        var tolerance: UInt64
    }

    private struct Record {
        var arms: [Arm] = []
        var parks = 0
        var armedDate: UInt64?
    }

    private let record = Mutex(Record())

    var arms: [Arm] { record.withLock { $0.arms } }
    var parks: Int { record.withLock { $0.parks } }
    var armedDate: UInt64? { record.withLock { $0.armedDate } }

    func arm(at date: UInt64, tolerance: UInt64, now: UInt64) {
        record.withLock { record in
            record.arms.append(Arm(date: date, tolerance: tolerance))
            record.armedDate = date
        }
    }

    func park() {
        record.withLock { record in
            record.parks += 1
            record.armedDate = nil
        }
    }

    /// What CFRunLoop does to the parked repeating timer when it fires: the next date is a park.
    func fired() {
        record.withLock { $0.armedDate = nil }
    }
}

/// The test's uptime, read by the queue from any thread.
final class FakeUptime: Sendable {
    private let value: Atomic<UInt64>

    init(_ start: UInt64 = 0) {
        value = Atomic(start)
    }

    var now: UInt64 {
        get { value.load(ordering: .relaxed) }
        set { value.store(newValue, ordering: .relaxed) }
    }
}
