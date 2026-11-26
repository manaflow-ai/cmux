import CoreFoundation
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CmuxMobileModel

/// The iPhone app's main-thread hang watchdog. Each test watches a run loop of its own, on a
/// thread of its own, so no test holds the real main thread or sees another suite's stalls.
@Suite(.serialized, .timeLimit(.minutes(1))) struct MainThreadHangWatchdogTests {
    #if DEBUG
    /// A deliberate stall on the watched thread is recorded with a non-empty stack that names
    /// the stalling function. The stall ends only once the watchdog thread sampled it, so host
    /// load cannot make the sample miss it.
    @Test func aStallIsRecordedWithItsStack() async throws {
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .seconds(30)))
        let sampled = HangTestFlag()
        watchdog.afterSampleForTesting.withLock { $0 = { sampled.set() } }
        await runOwnLoop(watchdog, seconds: 1) { stallForHangTest(until: sampled, atLeast: .milliseconds(150)) }
        #expect(sampled.isSet, "the watchdog thread did not sample the stall")
        let stall = try #require(watchdog.recentStalls().max { $0.duration < $1.duration }, "no stall recorded")
        #expect(stall.duration >= .milliseconds(150))
        #expect(!stall.addresses.isEmpty, "the stall has no stack")
        let symbols = stall.addresses.map(HangReports.symbolicate)
        #expect(symbols.contains { $0.contains("stallForHangTest") }, "frames: \(symbols.prefix(8))")
    }
    #endif

    /// A stall past the hang threshold reaches `onHang` twice (when it begins, still stuck, and
    /// when it ends, with its whole length), and the hang file is written, then rewritten.
    @Test func aHangIsReportedAndWrittenToAHangFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = HangReports(directory: directory, limit: 5)
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), hangThreshold: .milliseconds(300)))
        let seen = HangsSeen()
        watchdog.onHang = { hang in
            seen.hangs.withLock { $0.append(hang) }
            reports.record(hang)
        }
        await runOwnLoop(watchdog, seconds: 1.5) { spinForHangTest(.milliseconds(600)) }
        let hangs = seen.hangs.withLock { $0 }
        #expect(hangs.map(\.ended) == [false, true], "\(hangs)")
        let begun = try #require(hangs.first)
        #expect(begun.duration >= .milliseconds(300))
        #expect(!begun.addresses.isEmpty, "the hang has no stack")
        let ended = try #require(hangs.last)
        #expect(ended.duration >= .milliseconds(600))
        #expect(ended.startUptimeNanos == begun.startUptimeNanos)
        reports.drain()
        let files = reports.files()
        #expect(files.count == 1, "\(files)")
        let text = try String(contentsOf: try #require(files.first), encoding: .utf8)
        #expect(text.contains("state: ended"))
        #expect(text.contains("main thread stack (\(begun.addresses.count) frames)"))
    }

    /// The hangs directory keeps the newest files only.
    @Test func hangFilesAreBounded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hangs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = HangReports(directory: directory, limit: 3)
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            let hang = MainThreadHangWatchdog.Hang(startUptimeNanos: UInt64(index), duration: .seconds(3), addresses: [], ended: true)
            reports.record(hang, now: UInt64(index), date: base.addingTimeInterval(Double(index)))
        }
        reports.drain()
        let names = reports.files().map(\.lastPathComponent)
        #expect(names == [2, 3, 4].map { "hang-\(HangReports.stamp(base.addingTimeInterval(Double($0)))).txt" })
    }

    #if DEBUG
    /// An idle run loop costs the watchdog thread 0 wakeups, and short turns cost it none
    /// either: the main thread arms a kernel timer on wake and deletes it before sleep.
    /// Heartbeats driven by hand: first nothing for half a second, then 20 turns of
    /// microseconds, 80 ms apart (longer than the threshold).
    @Test func anIdleRunLoopCostsNoWatchdogWakeups() async throws {
        let watchdog = MainThreadHangWatchdog(configuration: .init(threshold: .milliseconds(50), sampleStacks: false))
        watchdog.running.store(true, ordering: .releasing)
        let thread = Thread { watchdog.watch(sampler: nil) }
        thread.start()
        defer { watchdog.stop() }
        // The thread parks: the run loop counts as asleep until its first heartbeat.
        try await Task.sleep(for: .milliseconds(100))
        let parked = watchdog.watchdogWakes.load(ordering: .relaxed)
        // Idle: the time asleep is the scenario under test, not a wait for a condition.
        try await Task.sleep(for: .milliseconds(500))
        #expect(watchdog.watchdogWakes.load(ordering: .relaxed) - parked == 0, "an idle run loop woke the watchdog")
        let before = watchdog.watchdogWakes.load(ordering: .relaxed)
        for _ in 0..<20 {
            watchdog.heartbeat(.afterWaiting)
            watchdog.heartbeat(.beforeWaiting)
            try await Task.sleep(for: .milliseconds(80))
        }
        let wakes = watchdog.watchdogWakes.load(ordering: .relaxed) - before
        #expect(wakes <= 2, "\(wakes) watchdog wakeups for 20 short turns")
        #expect(watchdog.recentStalls().isEmpty, "short turns are not stalls")
    }
    #endif
}

/// Starts `watchdog` on a new thread's run loop, runs `body` as that loop's first work, lets
/// the loop run (and sleep) until `seconds` pass, then stops the watchdog.
func runOwnLoop(_ watchdog: MainThreadHangWatchdog, seconds: Double, _ body: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        let thread = Thread {
            let runLoop: CFRunLoop = CFRunLoopGetCurrent()
            watchdog.start(runLoop: runLoop, thread: mach_thread_self())
            // A timer keeps the mode non-empty: an empty mode returns at once with no observer callouts.
            let keepAlive = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, keepAlive, .defaultMode)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { body() }
            CFRunLoopWakeUp(runLoop)
            CFRunLoopRunInMode(.defaultMode, seconds, false)
            CFRunLoopTimerInvalidate(keepAlive)
            watchdog.stop()
            done.resume()
        }
        thread.start()
    }
}

final class HangsSeen: Sendable {
    let hangs = Mutex<[MainThreadHangWatchdog.Hang]>([])
}

final class HangTestFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set() { value.store(true, ordering: .releasing) }
    var isSet: Bool { value.load(ordering: .acquiring) }
}

/// Busy until the watchdog sampled it and `atLeast` passed (at most 10 s).
@inline(never) func stallForHangTest(until sampled: HangTestFlag, atLeast: Duration) {
    let start = ContinuousClock.now
    while !(sampled.isSet && ContinuousClock.now - start >= atLeast), ContinuousClock.now - start < .seconds(10) {}
}

/// Busy for `duration`.
@inline(never) func spinForHangTest(_ duration: Duration) {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < duration {}
}
