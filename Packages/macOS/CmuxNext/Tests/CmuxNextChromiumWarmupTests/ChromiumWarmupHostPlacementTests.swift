import CmuxNextBrowser
@testable import CmuxNextChromiumWarmup
import CmuxNextInputCore
import CmuxNextInputCoreTestSupport
import Foundation
import Testing

/// With the Chromium Host the warm-up's `CefInitialize` step waits for neither the input
/// quiet nor a long idle slot, since the start holds the main thread only for the shim calls. The spare
/// window still follows the warm start: content makes its spare RenderProcessHost only after a navigation
/// took a process (`SpareRenderProcessHostManagerImpl::PrepareForFutureRequests`), so the spare window is
/// what is warm for the first tab. The bench-only `chromiumHostNoSpareWindow` drops it.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ChromiumWarmupHostPlacementTests {
    let idle = FakeIdle()
    let input = FakeInputTap()

    func warmup(_ engine: FakeWarmupEngine) -> ChromiumWarmup {
        ChromiumWarmup(engine: engine, idle: idle, input: input, memory: ManualMemoryLevelRegistry(),
                       isTrackingMenu: { false }, observeMenuEnd: { _ in NSObject() })
    }

    /// The host's warm start asks for the default profile's spare at the next idle step, before any tab
    /// navigates, so the first Cmd-Shift-L after it does not pay a cold window.
    @Test func theHostWarmStartPreparesTheDefaultProfilesSpare() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        #expect(warmup.startedPlacement == nil)
        warmup.start(defaultIsChromium: { true }, placement: .host())
        #expect(engine.onSpareWindowNeeded != nil, "the spare refill is not wired in host mode")
        #expect(warmup.startedPlacement == .host())

        warmup.startWithoutIdleWait(.launch)
        for _ in 0..<1_000 where engine.warmStarts.isEmpty { await Task.yield() }
        #expect(engine.warmStarts == ["launch"])
        await idle.posted(2)
        #expect(idle.queued.map(\.owner).contains("ChromiumWarmup.spare"), "the host warm start posted no spare step")

        idle.runPeriod()
        #expect(engine.prepared == [false], "the host warm start did not prepare the default profile's spare")
        warmup.stop()
    }

    /// The bench arm `chromiumHostNoSpareWindow`: no spare step, no refill, no pages spare.
    @Test func theNoSpareWindowArmBuildsNoSpareWindow() async {
        let engine = FakeWarmupEngine(running: false)
        let warmup = warmup(engine)
        warmup.start(defaultIsChromium: { true }, pagesSpare: { true }, placement: .host(spareWindows: false))
        #expect(engine.onSpareWindowNeeded == nil, "the spare refill was wired in the no spare window arm")
        #expect(warmup.startedPlacement?.keepsSpareWindows == false)

        warmup.startWithoutIdleWait(.launch)
        for _ in 0..<1_000 where engine.warmStarts.isEmpty { await Task.yield() }
        #expect(engine.warmStarts == ["launch"])
        for _ in 0..<100 { await Task.yield() }
        #expect(!idle.queued.contains { $0.owner == "ChromiumWarmup.spare" }, "a spare step was posted in the arm")

        warmup.pagesSpareChanged()
        warmup.pagesSettled()
        idle.runPeriod()
        #expect(engine.prepared.isEmpty, "a spare window was built in the arm")
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

    @Test func thePlacementsSayWhatHoldsTheMainThread() {
        #expect(ChromiumWarmup.Placement.inProcess == .init(startHoldsMainThread: true, keepsSpareWindows: true))
        #expect(ChromiumWarmup.Placement.host() == .init(startHoldsMainThread: false, keepsSpareWindows: true))
        #expect(!ChromiumWarmup.Placement.host(spareWindows: false).keepsSpareWindows)
        #expect(ChromiumWarmup.Placement(backend: .inProcess, hostNoSpareWindow: true) == .inProcess)
        #expect(ChromiumWarmup.Placement(backend: .host, hostNoSpareWindow: false) == .host())
        #expect(ChromiumWarmup.Placement(backend: .host, hostNoSpareWindow: true) == .host(spareWindows: false))
    }
}
