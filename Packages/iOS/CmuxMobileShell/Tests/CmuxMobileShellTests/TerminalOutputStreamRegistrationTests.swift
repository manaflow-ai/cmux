import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func lateOldStreamTerminationCannotUnregisterSameSurfaceRemount() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    let workspaceID = try #require(store.workspaceID(forTerminalID: surfaceID))
    await router.holdNextReplayResponses(count: 2)
    defer { Task { await router.releaseAllHeld() } }

    let oldStream = store.terminalOutputStream(surfaceID: surfaceID)
    let oldConsumer = Task { @MainActor in
        for await _ in oldStream {}
    }
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let currentStream = store.terminalOutputStream(surfaceID: surfaceID)
    var currentIterator = currentStream.makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let currentStreamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    let currentReplayToken = try #require(store.terminalReplayBarrierTokensBySurfaceID[surfaceID])

    let viewportSize = MobileTerminalViewportSize(columns: 91, rows: 37)
    let viewportKey = MobileTerminalViewportKey(
        workspaceID: workspaceID,
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID)
    )
    store.effectiveViewportSizesBySurfaceID[surfaceID] = viewportSize
    store.reportedTerminalViewportSizesBySurfaceID[surfaceID] = viewportSize
    store.reportTerminalViewport(
        workspaceID: workspaceID,
        terminalID: MobileTerminalPreview.ID(rawValue: surfaceID),
        viewportSize: viewportSize
    )
    store.viewportReportGenerationsBySurfaceID[surfaceID] = 41

    let retainedAccepted = store.deliverTerminalBytes(
        Data("retained-during-current-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(!retainedAccepted)
    #expect(store.terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID]?.deliveries.isEmpty == false)

    oldConsumer.cancel()
    await oldConsumer.value
    for _ in 0..<10 { await Task.yield() }

    #expect(store.hasTerminalOutputSink(surfaceID: surfaceID))
    #expect(store.terminalOutputStreamTokensBySurfaceID[surfaceID] == currentStreamToken)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == currentReplayToken)
    #expect(store.terminalReplayBarrierRetainedOutputBySurfaceID[surfaceID]?.deliveries.isEmpty == false)
    #expect(store.effectiveViewportSizesBySurfaceID[surfaceID] == viewportSize)
    #expect(store.reportedTerminalViewportSizesBySurfaceID[surfaceID] == viewportSize)
    #expect(store.reportedViewportSizesByTerminalKey[viewportKey] == viewportSize)
    #expect(store.viewportReportGenerationsBySurfaceID[surfaceID] == 41)
    guard store.hasTerminalOutputSink(surfaceID: surfaceID),
          store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == currentReplayToken else {
        return
    }

    _ = store.failOpenTerminalReplayBarrier(
        surfaceID: surfaceID,
        token: currentReplayToken,
        reason: "test_current_stream_delivery"
    )
    let retainedChunk = try #require(await currentIterator.next())
    #expect(String(data: retainedChunk.data, encoding: .utf8) == "retained-during-current-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: retainedChunk.streamToken)

    #expect(store.deliverTerminalBytes(Data("current-live".utf8), surfaceID: surfaceID))
    let liveChunk = try #require(await currentIterator.next())
    #expect(String(data: liveChunk.data, encoding: .utf8) == "current-live")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)
}
