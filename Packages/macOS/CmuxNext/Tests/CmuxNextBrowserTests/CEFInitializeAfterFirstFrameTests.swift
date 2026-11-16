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

    @Test func aStartAfterTheFirstFrameOrWithNoGateDoesNotWait() async {
        let gate = Self.gate()
        gate.open()
        #expect(await CEFRuntime.waitForInitializeGate(gate) == false)
        #expect(await CEFRuntime.waitForInitializeGate(nil) == false)
    }
}
