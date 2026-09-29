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

    @Test func hangLogIsBoundedDropOldest() {
        let log = HangLog(capacity: 3)
        for index in 0..<5 { log.append(startUptimeNanos: UInt64(index), duration: .milliseconds(60 + index), frames: []) }
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
