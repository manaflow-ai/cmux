@testable import CmuxNextControl
import CmuxNextWakeups
import Foundation
import Synchronization
import Testing

/// The busy watchdog (plans/cmux-next/idle-wakeups.md) records CPU use that
/// nothing explains, and nothing else.
@Suite(.serialized, .timeLimit(.minutes(1))) struct BusyWatchdogTests {
    final class Flag: Sendable {
        let value = Atomic(true)
    }

    private func spin(for duration: Duration, while condition: Flag) -> Thread {
        let thread = Thread {
            let end = ContinuousClock.now + duration
            while ContinuousClock.now < end, condition.value.load(ordering: .relaxed) {}
        }
        thread.start()
        return thread
    }

    private func settle(_ log: HangLog, window: Duration) async throws {
        try await Task.sleep(for: window + .milliseconds(250))
    }

    /// The shared machine can be heavily loaded, so a spinning thread may get
    /// a small share of a core; the threshold is low accordingly.
    @Test func unexplainedCPURecordsABusyWindow() async throws {
        let log = HangLog()
        let activity = ExpectedActivity()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), processThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: activity)
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        let busy = log.records().filter { $0.kind == .busy }
        #expect(busy.count >= 1)
        #expect(busy.first?.details["scope"] == "process")
        #expect(log.summary.busyCount >= 1)
        #expect(log.summary.count == 0)
    }

    @Test func cpuDuringInputIsExpected() async throws {
        let log = HangLog()
        let activity = ExpectedActivity()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(400), processThreshold: 0.05, logBusy: false),
                                    log: log, ledger: WakeupLedger(), activity: activity)
        let running = Flag()
        _ = spin(for: .seconds(2), while: running)
        watchdog.noteAwake()
        activity.note(.input)
        try await settle(log, window: .milliseconds(400))
        running.value.store(false, ordering: .relaxed)
        #expect(log.records().allSatisfy { $0.kind != .busy })
    }

    /// Other suites share this process's CPU, so the thresholds here are out
    /// of reach: this checks only that watching stops without a wake.
    @Test func withoutAWakeWatchingStopsAfterOneWindow() async throws {
        let log = HangLog()
        let ledger = WakeupLedger()
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(200), mainThreadThreshold: 100,
                                                         processThreshold: 100, helperThreshold: 100, logBusy: false),
                                    log: log, ledger: ledger, activity: ExpectedActivity())
        watchdog.noteAwake()
        try await settle(log, window: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(400))
        #expect(log.records().isEmpty)
        // One window, then idle: no further window deadlines.
        #expect(ledger.snapshot().first { $0.owner == "BusyWatchdog.window" }?.count == 1)
    }
}
