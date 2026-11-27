import Foundation
import Testing
@testable import CmuxMobileShell

/// `terminalOutputNeedsReplay` is the render-pipeline-reset entrypoint: the
/// local surface was just rebuilt blank, so nothing pre-barrier is visible.
/// Unlike intact-surface barriers, this one must drop the stale floor and the
/// alternate baseline at arm time and must NOT restore them when the replay
/// answers empty — restoring would claim content the rebuilt surface no
/// longer shows, dropping or gating the live output that should repaint it.
@MainActor
@Test func renderPipelineResetReplayDoesNotRestoreDestroyedBaseline() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    // Establish both baselines: a byte sequence and an alternate full frame.
    let transport = try #require(box.get())
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 900,
        text: "live-bytes-baseline"
    ))
    let byteBaselineDelivered = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 919
    }
    #expect(byteBaselineDelivered)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 950,
        text: "alt-baseline",
        activeScreen: .alternate,
        full: true
    ))
    let altBaselineDelivered = try await pollUntil {
        store.terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID)
    }
    #expect(altBaselineDelivered)

    // The render pipeline resets: the destroyed surface keeps neither a stale
    // floor to restore nor an alternate baseline, even while the replay is
    // held in flight.
    await router.holdNextReplayResponses()
    store.terminalOutputNeedsReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    #expect(store.terminalPreBarrierDeliveredEndSeqBySurfaceID[surfaceID] == nil)
    #expect(!store.terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID))

    // The replay answers empty: nothing is restored — the store must not
    // claim the rebuilt surface still shows the old content.
    await router.releaseAllHeld()
    let barrierReleasedWithoutRestore = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
            && !store.terminalAlternateRenderGridBaselineSurfaceIDs.contains(surfaceID)
    }
    #expect(
        barrierReleasedWithoutRestore,
        "a reset-triggered replay must not restore baselines for a destroyed surface"
    )

    // A live full alternate frame repaints the rebuilt surface from scratch.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 2000,
        text: "fresh-alt-full",
        activeScreen: .alternate,
        full: true
    ))
    let freshDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-alt-full") }
    }
    #expect(freshDelivered)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 2000)

    collector.unmount()
}
