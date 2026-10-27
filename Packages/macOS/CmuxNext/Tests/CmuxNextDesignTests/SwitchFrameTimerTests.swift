import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import QuartzCore
import Testing

/// `switch.workspace` (p09-observability 027): a ``SwitchFrameTimer`` with a signpost name makes every
/// switch one ``Signposter`` interval, recording or not: the intent begins its ring async pair and the
/// `CommitBoundary` after the turn that shows the switch ends it. A recorded row starts at the interval's
/// begin and its `signpost_ms` ends at the boundary, so the Debug row and the trace agree.
@MainActor @Suite(.serialized)
struct SwitchFrameTimerTests {
    private let key = "window-1"

    /// A runtime with only the `switch` category on (or every category off) that keeps its records.
    private func runtime(switchOn: Bool = true) -> (TraceRuntime, TraceRecordLog) {
        let log = TraceRecordLog()
        let runtime = TraceRuntime(role: .app, clock: TraceClock(), stubRecorder: { log.append($0) })
        runtime.setCategoryMask(switchOn ? 1 << UInt64(SignpostCategory.switch.traceBit) : 0)
        return (runtime, log)
    }

    /// Runs one main run-loop turn that polls and exits without waiting: its exit fires the boundary.
    private func pollingTurn() { turn(upTo: 0) }

    /// Runs the main run loop until a source is handled or `seconds` pass (a far-future timer keeps the
    /// mode non-empty, so the loop runs its observers instead of returning at once).
    private func turn(upTo seconds: CFTimeInterval) {
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 3_600, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        _ = CFRunLoopRunInMode(.defaultMode, seconds, true)
        CFRunLoopTimerInvalidate(timer)
    }

    @Test func aSwitchIsOneAsyncPairEndedAtItsCommitBoundaryWhileNotRecording() {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        #expect(!timer.isRecording)
        timer.began(key)
        #expect(log.phases == [.asyncBegin], "the intent writes the AB")
        timer.shown(key, in: nil)
        #expect(log.phases == [.asyncBegin], "the AE waits for the turn's commit boundary")
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd], "the boundary writes the AE")
        #expect(log.records.allSatisfy { $0.name == SignpostName.switchWorkspace.rawValue })
        #expect(log.records.last?.arg0 == 0, "a committed boundary ends it as committed")
        #expect(log.records.first?.arg1 == log.records.last?.arg1, "one async id pairs the AB and the AE")
        pollingTurn()
        #expect(log.records.count == 2, "the boundary runs once")
    }

    @Test func theBeginCarriesTheInputAgeInMicroseconds() throws {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        let now = CACurrentMediaTime()
        timer.began(key, at: now, inputTimestamp: now - 0.005)
        timer.began("window-2")
        let ages = log.records.filter { $0.phase == .asyncBegin }.map(\.arg0)
        try #require(ages.count == 2)
        #expect(ages[0] == 5_000, "a key or click 5 ms old")
        #expect(ages[1] == .max, "no input event: all ones")
    }

    @Test func aSecondIntentBeforeTheFirstShowsEndsTheFirstPairAsMissed() {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.began(key)
        #expect(log.phases == [.asyncBegin, .asyncEnd, .asyncBegin], "AB, AE (superseded), AB")
        #expect(log.records[1].arg0 == 1, "a superseded switch ends as a missed commit, so readers drop it")
        #expect(log.records[0].arg1 == log.records[1].arg1)
        #expect(log.records[1].arg1 != log.records[2].arg1)
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd, .asyncBegin, .asyncEnd])
        #expect(log.records[3].arg0 == 0)
    }

    @Test func aForgottenSwitchEndsItsPairAndAShownOneWithoutAnIntentWritesNothing() {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.forget(key)
        #expect(log.phases == [.asyncBegin, .asyncEnd])
        #expect(log.records.last?.arg0 == 1)
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(log.records.count == 2)
    }

    /// An intent that shows nothing in its turn (a top page, Home standing for the workspace, a machine still
    /// connecting) ends there as missed. A show of the same window in a later turn by a path with no intent of
    /// its own (an observation refill, a tab opened by an agent) must not end it as a committed switch that
    /// lasted the person's dwell time.
    @Test func anIntentThatShowsNothingInItsTurnEndsAsMissedAndALaterShowWritesNothing() {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.start()
        defer { timer.stop() }
        timer.began(key)
        pollingTurn()
        #expect(log.phases == [.asyncBegin, .asyncEnd], "the intent's turn ends its pair")
        #expect(log.records.last?.arg0 == 1, "a switch that did not show ends as a missed commit")
        #expect(!timer.isWaiting(key), "the recorded intent goes with its pair")
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(log.records.count == 2, "a show in a later turn ended a stale switch")
    }

    @Test func theSwitchCategoryOffWritesNoRecord() {
        let (trace, log) = runtime(switchOn: false)
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(log.records.isEmpty)
    }

    @Test func aTimerWithoutASignpostWritesNoRecord() {
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", trace: trace)
        timer.start()
        timer.began(key)
        timer.shown(key, in: nil)
        pollingTurn()
        timer.stop()
        #expect(log.records.isEmpty)
    }

    /// A recorded switch in a real window: the row waits for both the Core Animation commit (``CommitProbe``)
    /// and the boundary, and its `signpost_ms` is the ring pair's duration within 0.1 ms (the acceptance of
    /// task 027: the Debug row and the signpost read the same timestamps). The row's own reads are checked
    /// against the ring too: its `input_ms` (the Debug intent clock) is the AB's input age, and the switch it
    /// shows (`apply_ms`, read at `shown`) lies inside the ring pair.
    @Test func aRecordedRowAgreesWithTheRingPairWithinATenthOfAMillisecond() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: window.contentLayoutRect)
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        let frames = FrameScheduler.testing { _ in TimerFakeLink() }
        let (trace, log) = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace, frames: frames)
        timer.start()
        defer { timer.stop() }
        timer.began(key, inputTimestamp: CACurrentMediaTime() - 0.004)
        timer.shown(key, in: window)
        // The commit displays the probe and the boundary ends the pair; the probe's block runs a turn later.
        for _ in 0..<50 where timer.awaitsCommit { turn(upTo: 0.02) }
        try #require(!timer.awaitsCommit, "the window's commit never displayed the probe")
        frames.frameDidFire(timestamp: CACurrentMediaTime() + 0.001, refreshInterval: 1.0 / 120)
        let row = try #require(timer.samples.first)
        #expect(log.phases == [.asyncBegin, .asyncEnd])
        let signpost = try #require(row["signpost_ms"])
        let ringMs = Double(log.records[1].tNanos - log.records[0].tNanos) / 1_000_000
        #expect(abs(signpost - ringMs) < 0.1, "Debug \(signpost) ms, ring \(ringMs) ms")
        let input = try #require(row["input_ms"])
        #expect(abs(input - Double(log.records[0].arg0) / 1_000) < 0.1, "Debug input \(input) ms, AB age \(log.records[0].arg0) µs")
        let apply = try #require(row["apply_ms"])
        #expect(ringMs >= apply, "the ring pair ends after the switch showed: \(row)")
        #expect(row["signpost_missed"] == nil, "a polling turn's exit is a committed boundary: \(row)")
    }
}

@MainActor
private final class TimerFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
