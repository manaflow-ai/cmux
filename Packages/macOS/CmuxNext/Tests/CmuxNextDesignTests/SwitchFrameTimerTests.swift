import AppKit
import CmuxNextDesign
import CmuxNextSignposts
@testable import CmuxNextTrace
import CmuxNextWakeups
import QuartzCore
import Testing

/// `switch.workspace` (p09-observability 027): a ``SwitchFrameTimer`` with a signpost name makes every
/// switch one trace interval, recording or not: the intent begins the ring async pair and the
/// `CommitBoundary` after the turn that shows the switch ends it. A recorded row's `signpost_ms` is the
/// same interval, read from the same two timestamps.
@MainActor @Suite(.serialized)
struct SwitchFrameTimerTests {
    private let key = "window-1"

    /// A runtime with only the `switch` category on (or every category off).
    private func runtime(switchOn: Bool = true) -> TraceRuntime {
        let runtime = TraceRuntime(role: .app)
        runtime.setCategoryMask(switchOn ? 1 << UInt64(SignpostCategory.switch.traceBit) : 0)
        return runtime
    }

    private func records(_ runtime: TraceRuntime) -> UInt64 { runtime.stubRecordCount.load(ordering: .relaxed) }

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
        let trace = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        #expect(!timer.isRecording)
        timer.began(key)
        #expect(records(trace) == 1, "the intent writes the AB")
        timer.shown(key, in: nil)
        #expect(records(trace) == 1, "the AE waits for the turn's commit boundary")
        pollingTurn()
        #expect(records(trace) == 2, "the boundary writes the AE")
        pollingTurn()
        #expect(records(trace) == 2, "the boundary runs once")
    }

    @Test func aSecondIntentBeforeTheFirstShowsEndsTheFirstPair() {
        let trace = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.began(key)
        #expect(records(trace) == 3, "AB, AE (superseded), AB")
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(records(trace) == 4)
    }

    @Test func aForgottenSwitchEndsItsPairAndAShownOneWithoutAnIntentWritesNothing() {
        let trace = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.forget(key)
        #expect(records(trace) == 2)
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(records(trace) == 2)
    }

    @Test func theSwitchCategoryOffWritesNoRecord() {
        let trace = runtime(switchOn: false)
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace)
        timer.began(key)
        timer.shown(key, in: nil)
        pollingTurn()
        #expect(records(trace) == 0)
    }

    @Test func aTimerWithoutASignpostWritesNoRecord() {
        let trace = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", trace: trace)
        timer.start()
        timer.began(key)
        timer.shown(key, in: nil)
        pollingTurn()
        timer.stop()
        #expect(records(trace) == 0)
    }

    /// A recorded switch in a real window: the row waits for both the Core Animation commit (``CommitProbe``)
    /// and the boundary, and its `signpost_ms` lies between the shown selection and the next vsync tick.
    @Test func aRecordedRowCarriesTheSignpostInterval() throws {
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
        let trace = runtime()
        let timer = SwitchFrameTimer(owner: "test.switch", signpost: .switchWorkspace, trace: trace, frames: frames)
        timer.start()
        defer { timer.stop() }
        timer.began(key)
        timer.shown(key, in: window)
        // The commit displays the probe and the boundary ends the pair; the probe's block runs a turn later.
        for _ in 0..<50 where timer.awaitsCommit { turn(upTo: 0.02) }
        try #require(!timer.awaitsCommit, "the window's commit never displayed the probe")
        frames.frameDidFire(timestamp: CACurrentMediaTime() + 0.001, refreshInterval: 1.0 / 120)
        let row = try #require(timer.samples.first)
        #expect(records(trace) == 2)
        let signpost = try #require(row["signpost_ms"])
        let apply = try #require(row["apply_ms"])
        #expect(signpost >= apply, "the pair ends after the switch showed: \(row)")
        #expect(row["signpost_missed"] == nil, "a polling turn's exit is a committed boundary: \(row)")
    }
}

@MainActor
private final class TimerFakeLink: FrameLink {
    var isPaused = false
    func invalidate() {}
}
