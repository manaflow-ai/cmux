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
        #expect(watch.take(now: 100 + hang - 1, hangNanos: hang, parked: true) == .idle)
        guard case let .report(id, elapsed) = watch.take(now: 100 + hang, hangNanos: hang, parked: true) else {
            Issue.record("a run parked for the hang threshold is reported")
            return
        }
        #expect(elapsed == hang)
        #expect(watch.take(now: 100 + 2 * hang, hangNanos: hang, parked: true) == .idle, "reported once")
        #expect(watch.parkLimit(now: 100 + 2 * hang, hangNanos: hang) == nil, "nothing more to time while it runs")
        #expect(watch.exited(now: 100 + 3 * hang), "the end of a reported run wakes the watchdog")
        #expect(watch.take(now: 100 + 3 * hang, hangNanos: hang, parked: true) == .ended(id: id, durationNanos: 3 * hang))
        #expect(watch.take(now: 100 + 4 * hang, hangNanos: hang, parked: true) == .idle)
    }

    @Test func aRunThatEndsBeforeTheThresholdIsNeverReported() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: true)
        _ = watch.entered(now: 0, inDefaultMode: { true })
        #expect(!watch.exited(now: hang / 2))
        #expect(watch.take(now: 2 * hang, hangNanos: hang, parked: true) == .idle)
        #expect(watch.parkLimit(now: 2 * hang, hangNanos: hang) == nil)
    }

    /// A main thread busy in one turn inside the nested run is a hang the heartbeat reports. The
    /// nested run is not reported for it as well, and after it is timed again from the turn's end.
    @Test func aBusyTurnInsideANestedRunIsTheHeartbeatsHangNotAParkedRun() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: true)
        _ = watch.entered(now: 0, inDefaultMode: { true })
        #expect(watch.take(now: 2 * hang, hangNanos: hang, parked: false) == .idle, "busy, not parked")
        watch.hangTurnEnded(now: 2 * hang)
        #expect(watch.take(now: 2 * hang, hangNanos: hang, parked: true) == .idle, "the hang was reported once already")
        #expect(watch.parkLimit(now: 2 * hang, hangNanos: hang) == hang)
        #expect(watch.take(now: 3 * hang - 1, hangNanos: hang, parked: true) == .idle)
        #expect(watch.take(now: 3 * hang, hangNanos: hang, parked: true) == .report(id: 1, elapsedNanos: hang),
                "parked a full threshold after the hang ended")
    }

    @Test func menusModalPanelsAndTheOuterLoopAreNotTimed() {
        let watch = NestedRunLoopWatch()
        watch.start(insideRun: false)
        // The outer run (AppKit's event wait) is level 1.
        #expect(!watch.entered(now: 0, inDefaultMode: { true }))
        // A menu or a modal panel: a nested run in another mode.
        #expect(!watch.entered(now: 0, inDefaultMode: { false }))
        #expect(watch.take(now: 10 * hang, hangNanos: hang, parked: true) == .idle)
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

    /// End to end on the real main run loop: one busy turn past the hang threshold inside a nested
    /// default-mode run is one hang, reported once (the heartbeat's), not a second time as a parked run.
    @MainActor
    @Test func aBusyHangInsideARealNestedRunIsReportedOnce() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false,
                                                                hangThreshold: .milliseconds(200), hangAssertThreshold: nil))
        let reported = ReportedHangs()
        watchdog.onHang = { hang in reported.hangs.withLock { $0.append(hang) } }
        watchdog.start()
        defer { watchdog.stop() }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            busyOnTheMainThreadForTest(.milliseconds(600))
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let hangs = reported.hangs.withLock { $0 }
        #expect(hangs.count == 1, "one report for one busy hang, got \(hangs.count)")
    }

    /// End to end on the real main run loop: a nested default-mode run kept busy by many short turns (each far under
    /// the hang threshold) never lets the main thread sleep and takes no input. No turn is a hang, so the heartbeat
    /// reports nothing; the nested run is reported once.
    @MainActor
    @Test func aNestedRunBusyWithShortTurnsIsReportedOnce() {
        let watchdog = MainThreadWatchdog(configuration: .init(threshold: .milliseconds(50), logStalls: false,
                                                                hangThreshold: .milliseconds(200), hangAssertThreshold: nil))
        let reported = ReportedHangs()
        watchdog.onHang = { hang in reported.hangs.withLock { $0.append(hang) } }
        watchdog.start()
        defer { watchdog.stop() }
        let pump = ShortTurnPump(turn: .milliseconds(10), lasting: .milliseconds(800))
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            pump.run()
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        CFRunLoopRunInMode(.defaultMode, 30, false)
        let hangs = reported.hangs.withLock { $0 }
        #expect(pump.turns > 20, "the run turned many times: \(pump.turns)")
        #expect(hangs.count == 1, "one report for one nested run that never slept, got \(hangs.count)")
    }
}

/// Keeps the main run loop busy with short turns that never let it sleep: a version-0 source that signals itself
/// again from its own perform, so each run-loop pass handles a source and polls instead of waiting (no
/// before-waiting). Each turn is busy for `turn`; after `lasting` the source stops the run it was pumped in.
/// Main thread only (its source is on the main run loop, and `run()` is called there).
private final class ShortTurnPump {
    let turn: Duration
    let lasting: Duration
    private(set) var turns = 0
    private var deadline = ContinuousClock.now
    private var source: CFRunLoopSource?

    init(turn: Duration, lasting: Duration) {
        self.turn = turn
        self.lasting = lasting
    }

    /// Runs a nested default-mode run of the main run loop, pumped until `lasting` has passed.
    func run() {
        var context = CFRunLoopSourceContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                             copyDescription: nil, equal: nil, hash: nil, schedule: nil, cancel: nil,
                                             perform: { info in
                                                 guard let info else { return }
                                                 Unmanaged<ShortTurnPump>.fromOpaque(info).takeUnretainedValue().perform()
                                             })
        let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        defer {
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
        deadline = ContinuousClock.now + lasting
        CFRunLoopSourceSignal(source)
        CFRunLoopRunInMode(.defaultMode, 30, false)
    }

    private func perform() {
        turns += 1
        busyOnTheMainThreadForTest(turn)
        if ContinuousClock.now < deadline, let source {
            CFRunLoopSourceSignal(source)
        } else {
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }
}

/// The forced hang under test: keeps the main thread busy in one run-loop turn for `duration`.
@inline(never)
private func busyOnTheMainThreadForTest(_ duration: Duration) {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline { usleep(5_000) }
}

/// The nested run under test: sleeps in the main run loop's default mode, as `waitUntilExit()` does.
@inline(never)
private func parkInANestedRunLoopForTest(seconds: CFTimeInterval) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

private final class ReportedHangs: Sendable {
    let hangs = Mutex<[MainThreadWatchdog.Hang]>([])
}
