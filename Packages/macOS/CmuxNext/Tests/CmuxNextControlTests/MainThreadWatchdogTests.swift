@testable import CmuxNextControl
import CoreFoundation
import Foundation
import Testing

@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogTests {
    @MainActor
    @Test func recordsAMainThreadStallWithAStackSample() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false))
        watchdog.start()
        defer { watchdog.stop() }
        // Drive the main run loop so the observer sees activity, then stall inside one source.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallForTest()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 0.4, false)
        let records = watchdog.log.records()
        // The longest record: on a loaded machine a descheduled main thread
        // can add a shorter stall before the test's own one.
        let stall = try #require(records.max { $0.duration < $1.duration }, "no stall recorded")
        #expect(stall.duration >= .milliseconds(100))
        #expect(!stall.frames.isEmpty)
        #expect(stall.frames.contains { $0.symbol?.contains("stallForTest") == true },
                "frames: \(stall.frames.prefix(8).map(\.description))")
        // An idle run loop records nothing further.
        CFRunLoopRunInMode(.defaultMode, 0.2, false)
        #expect(watchdog.log.summary.count == records.count)
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
            stallForTest()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 0.4, false)
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
