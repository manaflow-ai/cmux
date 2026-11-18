@testable import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing

/// A launch that maps Chromium's framework early still runs `CefInitialize` (about 360 ms on the main
/// thread) only after the first window frame (CMUX-571): the start waits on the app's first-frame gate.
@MainActor
@Suite struct CEFInitializeAfterFirstFrameTests {
    private static func gate() -> FirstFrameGate {
        FirstFrameGate(backstop: DemandTimer(owner: "test", clock: ManualClock()))
    }

    @Test func aStartWaitsUntilTheFirstFrameOpensTheGate() async {
        let gate = Self.gate()
        var waited: Bool?
        let start = Task { @MainActor in waited = await CEFRuntime.waitForInitializeGate(gate) }
        for _ in 0..<20 { await Task.yield() }
        #expect(waited == nil)
        gate.open()
        await start.value
        #expect(waited == true)
    }

    /// Launch's preload maps the framework only once the first frame is up: the map holds dyld's loader lock, and
    /// the window being built takes that lock for each AppKit class it makes first. Base red: the map ran while
    /// the window built, and Leo's NIGHTLY held the main thread 3.5 s in `SidebarRailCardView.init` (hq#12524).
    @Test func launchPreloadMapsOnlyAfterTheFirstFrame() async {
        let gate = Self.gate()
        let log = CEFLibraryMapOffMainTests.LoaderLog()
        let runtime = CEFRuntime(libraryLoader: log.loader())
        runtime.initializeAfter = gate
        runtime.preload(layout: CEFLibraryMapOffMainTests.layout)
        // Give the load task every chance to run while the window builds.
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.onMain.isEmpty, "nothing mapped before the first frame")
        gate.open()
        _ = await runtime.loadTask?.value
        #expect(log.onMain == [false], "one map, after the first frame, off the main thread")
    }

    @Test func aStartAfterTheFirstFrameOrWithNoGateDoesNotWait() async {
        let gate = Self.gate()
        gate.open()
        #expect(await CEFRuntime.waitForInitializeGate(gate) == false)
        #expect(await CEFRuntime.waitForInitializeGate(nil) == false)
    }
}
