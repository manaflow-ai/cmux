@testable import CmuxNextControl
import CoreFoundation
import Foundation
import Synchronization
import Testing

@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogTests {
    #if DEBUG
    /// The watchdog reads an injected clock that moves only inside the
    /// stall, and the stall ends only once the watchdog thread sampled it:
    /// host load (a descheduled main thread, other suites' main-actor work,
    /// slow symbolication between runs) can neither add a stall nor make
    /// the sample miss this one (cx-onbb).
    @MainActor
    @Test func recordsAMainThreadStallWithAStackSample() throws {
        let clock = ManualUptime()
        let sampled = SampleSignal()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.fire() } }
        watchdog.start()
        defer { watchdog.stop() }
        // Stall inside one source of the main run loop, then end the run.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallForTestUntilSampled(clock: clock, by: .milliseconds(150), sampled: sampled)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        let records = watchdog.log.records()
        #expect(records.count == 1)
        let stall = try #require(records.first, "no stall recorded")
        #expect(stall.duration == .milliseconds(150))
        #expect(stall.frames.contains { $0.symbol?.contains("stallForTest") == true },
                "frames: \(stall.frames.prefix(8).map(\.description))")
        // The main thread works between the two runs (the symbolication
        // above; on a loaded host it takes longer than the threshold), then
        // the run loop idles: the clock did not move, nothing is recorded.
        // A timer keeps the mode non-empty: an empty mode returns at once
        // with no observer callouts, and this suite alone has nothing in it.
        spin(for: .milliseconds(60))
        let idle = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), idle, .defaultMode)
        defer { CFRunLoopTimerInvalidate(idle) }
        let beat = watchdog.currentBeat
        CFRunLoopRunInMode(.defaultMode, 0.2, false)
        #expect(watchdog.currentBeat != beat, "the idle run ran")
        #expect(watchdog.log.summary.count == 1)
    }
    #endif

    /// Time the main run loop sleeps is not a stall; time between waking and
    /// the next sleep is. Heartbeats driven by hand on an injected clock.
    @MainActor
    @Test func timeAsleepIsNotAStallAndWorkAwakeIs() {
        let clock = ManualUptime()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.heartbeat(.afterWaiting)
        clock.advance(by: .milliseconds(10))
        watchdog.heartbeat(.beforeWaiting)
        clock.advance(by: .seconds(5))
        watchdog.heartbeat(.afterWaiting)
        #expect(watchdog.log.summary.count == 0, "10 ms of work and 5 s asleep")
        clock.advance(by: .milliseconds(80))
        watchdog.heartbeat(.beforeWaiting)
        #expect(watchdog.log.records().map(\.duration) == [.milliseconds(80)])
        #expect(watchdog.log.summary.count == 1)
    }

    /// AppKit lays out, displays and commits Core Animation in
    /// before-waiting observers (order 2,000,000 for the CA commit). That
    /// work is main-thread time before the loop sleeps; a stall there must
    /// count like a stall inside a source.
    @MainActor
    @Test func recordsAStallInABeforeWaitingObserverLikeDisplayAndCommit() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        watchdog.start()
        defer { watchdog.stop() }
        var fired = false
        let commit = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 2_000_000) { _, _ in
            guard !fired else { return }
            fired = true
            stallForTest()
            // End the run right after this pass (the watchdog's late
            // observer still stamps it): the test holds the main actor
            // only as long as it must, since other suites wait for it.
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        defer { CFRunLoopObserverInvalidate(commit) }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 0.4, false)
        #expect(fired)
        let stall = try #require(watchdog.log.records().max { $0.duration < $1.duration },
                                 "a stall in a before-waiting observer was not recorded")
        #expect(stall.duration >= .milliseconds(100))
        #expect(watchdog.gapStats.max >= .milliseconds(100))
    }

    #if DEBUG
    /// The watchdog thread can lose the CPU right after it samples a stall.
    /// The stall may then end before the sample is handed over; the record
    /// must still carry the stack that was taken during the stall.
    @MainActor
    @Test func aSampleTakenDuringTheStallIsKeptWhenTheStallEndsFirst() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        watchdog.afterSampleForTesting.withLock { hook in
            hook = { [watchdog] in
                // Hold the watchdog thread until the main thread's next heartbeat (the stall's end).
                let beat = watchdog.currentBeat
                let deadline = ContinuousClock.now + .seconds(2)
                while watchdog.currentBeat == beat, ContinuousClock.now < deadline { usleep(1_000) }
            }
        }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallForTestLong()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 1.0, false)
        // The full package run shares the main run loop with other tests, so
        // other stalls can be recorded too; one record must be this stall's.
        let records = watchdog.log.records()
        try #require(!records.isEmpty, "no stall recorded")
        #expect(records.contains { $0.frames.contains { $0.symbol?.contains("stallForTest") == true } },
                "frames: \(records.map { $0.frames.prefix(4).map(\.description) })")
    }
    #endif

    @Test func hangLogIsBoundedDropOldest() {
        let log = HangLog(capacity: 3)
        for index in 0..<5 { log.append(startUptimeNanos: UInt64(index), duration: .milliseconds(60 + index), addresses: []) }
        let records = log.records()
        #expect(records.map(\.startUptimeNanos) == [2, 3, 4])
        #expect(log.summary.count == 5)
        #expect(log.summary.maxDuration == .milliseconds(64))
    }
}

@inline(never)
func stallForTest() {
    spin(for: .milliseconds(150))
}

/// A longer stall, so a loaded host's watchdog thread still wakes inside it
/// (the sample is due 30 ms in).
@inline(never)
func stallForTestLong() {
    spin(for: .milliseconds(500))
}

/// Spins inside a symbol the stack sample can name: moves the injected clock
/// past the threshold, then holds the main thread until the watchdog thread
/// sampled it (a 20 s wall-clock bound turns a missing sample into a test
/// failure, not a hang).
@inline(never)
func stallForTestUntilSampled(clock: ManualUptime, by duration: Duration, sampled: SampleSignal) {
    clock.advance(by: duration)
    let deadline = ContinuousClock.now + .seconds(20)
    while !sampled.hasFired, ContinuousClock.now < deadline {}
}

/// An uptime clock (nanoseconds) that moves only when the test moves it.
final class ManualUptime: Sendable {
    private let nanos = Atomic<UInt64>(1_000_000_000)
    var read: @Sendable () -> UInt64 { { [self] in nanos.load(ordering: .acquiring) } }
    func advance(by duration: Duration) {
        nanos.add(UInt64(duration.components.seconds) * 1_000_000_000 + UInt64(duration.components.attoseconds / 1_000_000_000),
                  ordering: .releasing)
    }
}

/// Set once by the watchdog thread after it sampled the main thread.
final class SampleSignal: Sendable {
    private let fired = Atomic(false)
    var hasFired: Bool { fired.load(ordering: .acquiring) }
    func fire() { fired.store(true, ordering: .releasing) }
}
