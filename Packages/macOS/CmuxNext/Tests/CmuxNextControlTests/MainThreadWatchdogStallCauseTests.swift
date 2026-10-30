@testable import CmuxNextControl
import CoreFoundation
import Darwin
import Foundation
import CmuxNextCompat
import CmuxNextSettings
import Testing

/// Rule G (stall reports): a stall whose main thread used CPU for under half of its wall time is a
/// WAIT (paging, a lock, a descheduled thread), not code to fix; only one at or above half is a CODE
/// stall named by its stack. The same half rule as the debug hang assertion. A wait carries the page
/// faults the process took during it, read on the watchdog thread, never on main.
/// (Austin's-day run 1, 2026-10-30: FrameScheduler.drop "stalled" 3,348.9 ms on 8.4 ms of CPU while a
/// memory hog held 13.5 GB; every one of 92 stalls over 100 ms used under 30 % CPU.)
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadWatchdogStallCauseTests {
    @Test func aStallMostlyOffCPUIsAWaitAndOneAtHalfOrMoreIsCode() {
        let log = HangLog(capacity: 8)
        let wait = log.append(startUptimeNanos: 1, duration: .microseconds(3_348_892), cpu: .microseconds(8_428), addresses: [])
        let code = log.append(startUptimeNanos: 2, duration: .milliseconds(100), cpu: .milliseconds(60), addresses: [])
        let half = log.append(startUptimeNanos: 3, duration: .milliseconds(100), cpu: .milliseconds(50), addresses: [])
        let justUnder = log.append(startUptimeNanos: 4, duration: .milliseconds(100), cpu: .microseconds(49_999), addresses: [])
        #expect(wait.json["cause"]?.stringValue == "wait")
        #expect(code.json["cause"]?.stringValue == "code")
        #expect(half.json["cause"]?.stringValue == "code", "at half the wall time the main thread computed")
        #expect(justUnder.json["cause"]?.stringValue == "wait")
    }

    #if DEBUG
    /// A stall that takes page faults: the record carries the process's faults from the sample to
    /// the stall's end (at least the pages the stall touched), and the length of that window.
    @MainActor
    @Test func aStallRecordsThePageFaultsTakenDuringIt() throws {
        let clock = ManualUptime()
        let sampled = SampleSignal()
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false), uptime: clock.read)
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.fire() } }
        let pageSize = Int(getpagesize())
        let pages = 512
        let region = try #require(FreshPages(count: pages, pageSize: pageSize))
        defer { region.unmap() }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            stallTouchingPagesAfterSample(clock: clock, by: .milliseconds(150), sampled: sampled, region: region)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        #expect(sampled.hasFired, "the watchdog thread did not sample the stall")
        // The watchdog thread closes the fault window on its first pass after the stall ended.
        let deadline = ContinuousClock.now + .seconds(5)
        var stall = watchdog.log.records().first { $0.duration == .milliseconds(150) }
        while stall?.json["task_faults"] == nil, ContinuousClock.now < deadline {
            usleep(5_000)
            stall = watchdog.log.records().first { $0.duration == .milliseconds(150) }
        }
        let record = try #require(stall, "no stall recorded")
        let faults = try #require(record.json["task_faults"]?.doubleValue, "the stall has no fault count: \(record.json)")
        #expect(faults >= Double(pages), "\(faults) faults for \(pages) fresh pages touched in the stall")
        #expect(record.json["task_pageins"]?.doubleValue != nil)
        #expect((record.json["fault_window_ms"]?.doubleValue ?? 0) > 0)
    }
    #endif
}

/// Anonymous memory never touched before: the first write to each page is a page fault.
/// Held as an address so the stall's run-loop block can carry it.
struct FreshPages: Sendable {
    let address: UInt
    let count: Int
    let pageSize: Int

    init?(count: Int, pageSize: Int) {
        guard let mapped = mmap(nil, count * pageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        address = UInt(bitPattern: mapped)
        self.count = count
        self.pageSize = pageSize
    }

    func touchAll() {
        guard let base = UnsafeMutableRawPointer(bitPattern: address) else { return }
        for page in 0..<count { base.storeBytes(of: 1, toByteOffset: page * pageSize, as: UInt8.self) }
    }

    func unmap() { munmap(UnsafeMutableRawPointer(bitPattern: address), count * pageSize) }
}

/// Moves the injected clock past the threshold, holds the main thread until the watchdog thread
/// sampled it, then takes a page fault on every page of `region` before the stall ends.
@inline(never)
func stallTouchingPagesAfterSample(clock: ManualUptime, by duration: Duration, sampled: SampleSignal, region: FreshPages) {
    clock.advance(by: duration)
    let deadline = ContinuousClock.now + .seconds(20)
    while !sampled.hasFired, ContinuousClock.now < deadline {}
    region.touchAll()
}
