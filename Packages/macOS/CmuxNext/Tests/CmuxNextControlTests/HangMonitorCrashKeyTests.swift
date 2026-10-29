@testable import CmuxNextControl
import CmuxNextCompat
import CmuxNextSettings
import CmuxNextTrace
import CmuxNextWakeups
import Foundation
import Testing

/// The hang monitor names each reported thread in the crash keys' hung threads until its scope ends
/// (Chrome's `HangWatcher` crash keys): driven on an injected clock, one service call
/// at a time, with the scope held open on a thread of its own.
@Suite(.serialized, .timeLimit(.minutes(1))) struct HangMonitorCrashKeyTests {
    @Test func aReportedScopeIsNamedUntilItEndsEvenWhenTheMonitorParked() throws {
        let now = Counter(1_000_000_000)
        let watch = HangWatch(clock: TraceClock(reader: .init(uptimeNanos: { now.value }, continuousNow: { ContinuousClock.now })))
        let wakes = Counter(0)
        let attached = watch.attachMonitor(wake: { wakes.add(1) })
        try #require(attached)
        let keys = CrashKeySlots()
        let log = HangLog(capacity: 8)
        var monitor = HangMonitor(source: HangMonitor.Source(watch: watch, crashKeys: keys), log: log, janks: HangLog(capacity: 8), logger: nil,
                                  intervalNanos: 0, deliver: { _ in })
        let scope = HeldScope(watch: watch)

        now.add(2_500_000_000) // past the 100 ms budget and the 2 s hang tier after it
        _ = monitor.service()
        #expect(keys.snapshot().hungThreadCount == 1, "the reported scope's thread is not named")
        #expect(keys.snapshot().hungThread(at: 0)?.kind == HangWatch.ThreadKind.io.rawValue)
        let record = try #require(log.records().first)
        #expect(record.details["crash_keys"] != nil, "the hang report carries no crash keys")

        now.add(200_000_000) // a scan that sees no change parks the monitor
        #expect(monitor.service() == nil)
        #expect(watch.nextScanNanos == nil)

        let wakesBefore = wakes.value
        scope.close()
        #expect(wakes.value > wakesBefore, "the reported scope's end did not wake the parked monitor")
        #expect(watch.nextScanNanos != nil)
        _ = monitor.service()
        #expect(keys.snapshot().hungThreadCount == 0, "the thread stayed named after its scope ended")
    }
}

/// A scope opened on a thread of its own, held until ``close()``: the monitor samples a live thread.
private final class HeldScope: Sendable {
    private let opened = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)

    init(watch: HangWatch) {
        let (opened, release, closed) = (opened, release, closed)
        let thread = Thread {
            let registration = watch.registerThread(.io, name: "test.crash_keys")
            let scope = watch.watch(registration, deadline: .milliseconds(100))
            opened.signal()
            release.wait()
            scope.close()
            watch.unregister(registration)
            closed.signal()
        }
        thread.start()
        opened.wait()
    }

    /// Closes the scope and returns once it is closed.
    func close() {
        release.signal()
        closed.wait()
    }
}

/// A number the test moves and the clock or the wake closure reads on another thread.
private final class Counter: Sendable {
    private let word: Atomic<UInt64>

    init(_ value: UInt64) {
        word = Atomic(value)
    }

    var value: UInt64 { word.load(ordering: .relaxed) }

    func add(_ amount: UInt64) {
        _ = word.add(amount, ordering: .relaxed)
    }
}
