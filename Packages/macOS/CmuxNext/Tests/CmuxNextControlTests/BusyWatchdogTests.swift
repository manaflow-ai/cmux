@testable import CmuxNextControl
import CmuxNextWakeups
import Foundation
import CmuxNextCompat
import Testing

/// The busy watchdog (plans/cmux-next/idle-wakeups.md) records CPU use that
/// nothing explains, and nothing else.
@Suite(.serialized, .timeLimit(.minutes(1))) struct BusyWatchdogTests {
    /// The production read path must not grow reabstraction thunks in the
    /// stored callback. Invoke on a cooperative thread like DemandTimer does.
    @Test func helperSourceSurvivesFiftyThousandReads() async {
        await Task.detached {
            let watchdog = BusyWatchdog(log: HangLog(), ledger: WakeupLedger(), activity: ExpectedActivity())
            watchdog.setHelperSource { [.init(pid: 42, label: "Chromium tab")] }
            var source = watchdog.helperSource()
            for _ in 0..<50_000 {
                source = watchdog.helperSource()
            }
            let helpers = source()
            #expect(helpers.count == 1)
            #expect(helpers.first?.pid == 42)
            #expect(helpers.first?.label == "Chromium tab")
        }.value
    }

    @Test func helperSourceCanReplaceItselfOutsideTheLock() {
        let watchdog = BusyWatchdog(log: HangLog(), ledger: WakeupLedger(), activity: ExpectedActivity())
        watchdog.setHelperSource {
            watchdog.setHelperSource { [.init(pid: 43, label: "Replacement")] }
            return [.init(pid: 42, label: "Original")]
        }
        #expect(watchdog.helperSource()().first?.pid == 42)
        #expect(watchdog.helperSource()().first?.pid == 43)
    }

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

    /// Records each kernel read of the watchdog and the reads that ran on the main thread; a test awaits a count.
    final class ProbeReads: Sendable {
        private struct State {
            var reads: [String] = []
            var onMain: [String] = []
            var waiter: (count: Int, done: CheckedContinuation<Void, Never>)?
        }

        // concurrency-allow: test recorder; the probe's reads append from the watchdog's threads, the test reads after them.
        private let state = Mutex(State())

        /// The real kernel reads, each recorded first.
        var probe: BusyWatchdog.Probe {
            BusyWatchdog.Probe(usage: { [self] pid in
                note("usage(\(pid))")
                return ProcessUsage.sample(pid)
            }, threadCPUNanos: { [self] thread in
                note("thread_info")
                return BusyWatchdog.cpuNanos(of: thread)
            })
        }

        func note(_ read: String) {
            let onMain = pthread_main_np() != 0
            let done = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.reads.append(read)
                if onMain { state.onMain.append(read) }
                guard let waiter = state.waiter, state.reads.count >= waiter.count else { return nil }
                state.waiter = nil
                return waiter.done
            }
            done?.resume()
        }

        /// Returns once `count` reads have run (the suite's time limit ends a run that never gets them).
        func reached(_ count: Int) async {
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { state -> Bool in
                    guard state.reads.count < count else { return true }
                    state.waiter = (count, done)
                    return false
                }
                if ready { done.resume() }
            }
        }

        var all: [String] { state.withLock { $0.reads } }
        var onMain: [String] { state.withLock { $0.onMain } }
    }

    /// The watchdog watches the main thread, so it must never block it. Every kernel read (each process's
    /// `proc_pid_rusage` and `proc_pidinfo`, the helper list's `proc_listchildpids`, the main thread's
    /// `thread_info`) runs off the main thread, also for the window that a main-thread wake opens.
    /// The main thread only stamps that it woke. v229 (2026-10-30): one window end stalled the main thread
    /// 1,261 ms in `proc_pidinfo`, and three window opens 111-381 ms in the helper list.
    @MainActor @Test func kernelReadsNeverRunOnTheMainThread() async throws {
        let reads = ProbeReads()
        // Out-of-reach thresholds: this checks where the reads run, not what they find.
        let watchdog = BusyWatchdog(configuration: .init(window: .milliseconds(50), mainThreadThreshold: 100, processThreshold: 100,
                                                         helperThreshold: 100, logBusy: false),
                                    log: HangLog(), ledger: WakeupLedger(), activity: ExpectedActivity(), clock: ContinuousClock(),
                                    probe: reads.probe)
        let me = getpid()
        watchdog.watchCurrentThread()
        watchdog.setHelperSource {
            reads.note("helpers")
            return [.init(pid: me, label: "cef-renderer")]
        }
        // As MainThreadWatchdog.heartbeat does when the main run loop wakes.
        watchdog.noteAwake()
        // The open (helpers, helper usage, app usage, thread_info) and the close (thread_info, app usage,
        // helper usage) of the one window: no wake follows, so no second window opens.
        await reads.reached(7)
        #expect(reads.all.count == 7)
        #expect(reads.onMain.isEmpty, "kernel reads on the main thread: \(reads.onMain)")
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
