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
        let stall = try #require(records.first, "no stall recorded")
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
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), commit, .commonModes)
        defer { CFRunLoopObserverInvalidate(commit) }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 0.4, false)
        #expect(fired)
        let stall = try #require(watchdog.log.records().first, "a stall in a before-waiting observer was not recorded")
        #expect(stall.duration >= .milliseconds(100))
        #expect(watchdog.gapStats.max >= .milliseconds(100))
    }

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
