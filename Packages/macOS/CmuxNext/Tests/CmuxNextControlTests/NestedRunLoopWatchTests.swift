@testable import CmuxNextControl
import CoreFoundation
import Foundation
import CmuxNextCompat
import Testing

/// Leo's NIGHTLY was force quit twice on 2026-11-09 (19:17Z and 19:48Z, the Dock's "Application Not
/// Responding") and left no hang file: the main run loop kept sleeping and waking, so the heartbeat
/// read it as idle. A nested default-mode run that takes no input is now timed apart and reported.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NestedRunLoopWatchTests {
    private let hang: UInt64 = 2_000_000_000

    @Test func aNestedDefaultModeRunWithNoInputIsReportedOnceAndEnds() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: true)
        #expect(watch.entered(now: 100, inDefaultMode: { true }), "a nested default-mode run wakes the watchdog")
        #expect(watch.parkLimit(now: 100, hangNanos: hang) == hang)
        #expect(watch.take(now: 100 + hang - 1, hangNanos: hang) == .idle)
        guard case let .report(id, elapsed) = watch.take(now: 100 + hang, hangNanos: hang) else {
            Issue.record("a run parked for the hang threshold is reported")
            return
        }
        #expect(elapsed == hang)
        #expect(watch.take(now: 100 + 2 * hang, hangNanos: hang) == .idle, "reported once")
        #expect(watch.parkLimit(now: 100 + 2 * hang, hangNanos: hang) == nil, "nothing more to time while it runs")
        #expect(watch.exited(now: 100 + 3 * hang), "the end of a reported run wakes the watchdog")
        #expect(watch.take(now: 100 + 3 * hang, hangNanos: hang) == .ended(id: id, durationNanos: 3 * hang))
        #expect(watch.take(now: 100 + 4 * hang, hangNanos: hang) == .idle)
    }

    @Test func aRunThatEndsBeforeTheThresholdIsNeverReported() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: true)
        _ = watch.entered(now: 0, inDefaultMode: { true })
        #expect(!watch.exited(now: hang / 2))
        #expect(watch.take(now: 2 * hang, hangNanos: hang) == .idle)
        #expect(watch.parkLimit(now: 2 * hang, hangNanos: hang) == nil)
    }

    @Test func menusModalPanelsAndTheOuterLoopAreNotTimed() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: false)
        // The outer run (AppKit's event wait) is level 1.
        #expect(!watch.entered(now: 0, inDefaultMode: { true }))
        // A menu or a modal panel: a nested run in another mode.
        #expect(!watch.entered(now: 0, inDefaultMode: { false }))
        #expect(watch.take(now: 10 * hang, hangNanos: hang) == .idle)
        _ = watch.exited(now: 10 * hang)
        _ = watch.exited(now: 10 * hang)
        // An unbalanced exit (watching began inside a nested run) never goes below zero.
        _ = watch.exited(now: 10 * hang)
        #expect(!watch.entered(now: 0, inDefaultMode: { true }), "back at level 1")
    }

    /// End to end on the real main run loop: a `CFRunLoopRunInMode` nested in a callout sleeps the
    /// whole time (the heartbeat sees an idle loop), and the watchdog still reports it with a stack.
    @MainActor
    @Test func theWatchdogReportsARealNestedRunWithAStack() throws {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false,
                                                                hangThreshold: .milliseconds(200), hangAssertThreshold: nil))
        let reported = ReportedHangs()
        watchdog.onHang = { hang in reported.hangs.withLock { $0.append(hang) } }
        watchdog.start()
        defer { watchdog.stop() }
        // A timer keeps the default mode non-empty: an empty mode returns at once.
        let keep = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), keep, .defaultMode)
        defer { CFRunLoopTimerInvalidate(keep) }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            parkInANestedRunLoopForTest(seconds: 0.8)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let hangs = reported.hangs.withLock { $0 }
        #expect(hangs.count == 1, "one report for one parked run, got \(hangs.count)")
        let first = try #require(hangs.first)
        #expect(first.duration >= .milliseconds(200))
        #expect(!first.addresses.isEmpty, "the main thread's stack names the nested run's caller")
    }
}

/// The nested run under test: sleeps in the main run loop's default mode, as `waitUntilExit()` does.
@inline(never)
private func parkInANestedRunLoopForTest(seconds: CFTimeInterval) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

private final class ReportedHangs: Sendable {
    let hangs = Mutex<[MainThreadWatchdog.Hang]>([])
}
