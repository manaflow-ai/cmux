import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import Foundation
import Testing

/// p01-process-086: with the Chromium Host the warm-up keeps no spare window (content's spare
/// RenderProcessHost serves the next tab, and the host builds windows off cmux's main thread), and its
/// `CefInitialize` step waits for neither the input quiet nor a long idle slot, since the start holds the
/// main thread only for the shim calls. The bench-only `chromiumHostSpareWindow` keeps the spare window.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupHostPlacementTests {
    let idle = FakeIdle()
    let input = FakeInputTap()

    func warmup(_ engine: FakeWarmupEngine) -> ChromiumWarmup {
        ChromiumWarmup(engine: engine, idle: idle, input: input, memory: ManualMemoryLevelRegistry(),
                       isTrackingMenu: { false }, observeMenuEnd: { _ in NSObject() })
    }

    @Test func theHostPlacementBuildsNoSpareWindow() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        warmup.start(defaultIsChromium: { true }, pagesSpare: { true }, placement: .host())
        #expect(engine.onSpareWindowNeeded == nil, "the spare refill was wired in host mode")

        warmup.startWithoutIdleWait(.launch)
        for _ in 0..<1_000 where engine.warmStarts.isEmpty { await Task.yield() }
        #expect(engine.warmStarts == ["launch"])
        for _ in 0..<100 { await Task.yield() }
        #expect(!idle.queued.contains { $0.owner == "ChromiumWarmup.spare" }, "a spare step was posted in host mode")

        warmup.pagesSpareChanged()
        warmup.pagesSettled()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a spare window was built in host mode")
        #expect(engine.droppedPages == 0)
        warmup.stop()
    }

    /// The person typing does not hold the host's start: its step runs in the next idle period, even a
    /// short one between frames.
    @Test func theHostStartWaitsForNoInputQuietOrLongSlot() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        warmup.start(defaultIsChromium: { false }, placement: .host())
        idle.runPeriod()
        warmup.chromiumLikely(.newTabMenu)
        await idle.posted(2)
        #expect(idle.queued.map(\.owner) == ["ChromiumWarmup.initialize"])

        let at = (idle.now - .milliseconds(10)).components
        input.deliver(InputEventRecord(type: .keyDown, timestamp: Double(at.seconds) + Double(at.attoseconds) * 1e-18))
        idle.runPeriod(mayOverrun: false)
        for _ in 0..<1_000 where engine.warmStarts.isEmpty { await Task.yield() }
        #expect(engine.warmStarts == ["newTabMenu"])
        #expect(idle.afters.isEmpty, "the host start waited for the input quiet")
        warmup.stop()
    }

    /// In process the same step still waits for the quiet (the regression guard for the in-process path).
    @Test func theInProcessStartStillWaitsForTheInputQuiet() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        warmup.start(defaultIsChromium: { false })
        idle.runPeriod()
        warmup.chromiumLikely(.newTabMenu)
        await idle.posted(2)

        let at = (idle.now - .milliseconds(10)).components
        input.deliver(InputEventRecord(type: .keyDown, timestamp: Double(at.seconds) + Double(at.attoseconds) * 1e-18))
        idle.runPeriod()
        for _ in 0..<100 { await Task.yield() }
        #expect(engine.warmStarts.isEmpty)
        #expect(idle.afters.map(\.owner) == ["ChromiumWarmup.quiet"])
        warmup.stop()
    }

    /// The bench arm: `chromiumHostSpareWindow` keeps the spare window as in process.
    @Test func theBenchArmKeepsTheSpareWindowInHostMode() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        warmup.start(defaultIsChromium: { true }, placement: .host(spareWindows: true))
        #expect(engine.onSpareWindowNeeded != nil)

        warmup.startWithoutIdleWait(.launch)
        await idle.posted(2)
        #expect(idle.queued.map(\.owner).contains("ChromiumWarmup.spare"))
        warmup.stop()
    }

    @Test func thePlacementsSayWhatHoldsTheMainThread() {
        #expect(ChromiumWarmup.Placement.inProcess == .init(startHoldsMainThread: true, keepsSpareWindows: true))
        #expect(ChromiumWarmup.Placement.host() == .init(startHoldsMainThread: false, keepsSpareWindows: false))
        #expect(ChromiumWarmup.Placement.host(spareWindows: true).keepsSpareWindows)
        #expect(ChromiumWarmup.Placement(backend: .inProcess, hostSpareWindows: true) == .inProcess)
        #expect(ChromiumWarmup.Placement(backend: .host, hostSpareWindows: false) == .host())
        #expect(ChromiumWarmup.Placement(backend: .host, hostSpareWindows: true) == .host(spareWindows: true))
    }
}
