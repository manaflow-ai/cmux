import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func queuedRenderGridOlderThanDeliveredHighWaterIsSkipped() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    store.deliverTerminalBytes(Data("blocked".utf8), surfaceID: surfaceID)
    let blockedChunk = try #require(await iterator.next())
    let staleFrame = try renderGridFrame(surfaceID: surfaceID, seq: 4, text: "old")
    #expect(store.deliverTerminalRenderGrid(staleFrame, surfaceID: surfaceID))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 12, fullReplacement: true)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: blockedChunk.streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    let currentFrame = try renderGridFrame(surfaceID: surfaceID, seq: 12, text: "current")
    #expect(store.deliverTerminalRenderGrid(currentFrame, surfaceID: surfaceID))
    let currentChunk = try #require(await iterator.next())
    let currentText = try #require(String(data: currentChunk.data, encoding: .utf8))
    #expect(currentText.contains("current"))
    #expect(!currentText.contains("old"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: currentChunk.streamToken)
}

@MainActor
@Test func staleQueuedReplayRenderGridClearsBarrierWithoutPaintingOldFrame() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let currentFrame = try renderGridFrame(surfaceID: surfaceID, seq: 12, text: "current")
    #expect(store.deliverTerminalRenderGrid(
        currentFrame,
        surfaceID: surfaceID,
        bypassReplayBarrier: true
    ))
    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 12, fullReplacement: true)
    let currentChunk = try #require(await iterator.next())
    let currentText = try #require(String(data: currentChunk.data, encoding: .utf8))
    #expect(currentText.contains("current"))

    let staleFrame = try renderGridFrame(surfaceID: surfaceID, seq: 4, text: "old")
    #expect(store.deliverTerminalRenderGrid(
        staleFrame,
        surfaceID: surfaceID,
        bypassReplayBarrier: true
    ))
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 1)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: currentChunk.streamToken)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != barrierToken)

    let afterFrame = try renderGridFrame(surfaceID: surfaceID, seq: 13, text: "after")
    #expect(store.deliverTerminalRenderGrid(afterFrame, surfaceID: surfaceID))
    let afterChunk = try #require(await iterator.next())
    let afterText = try #require(String(data: afterChunk.data, encoding: .utf8))
    #expect(afterText.contains("after"))
    #expect(!afterText.contains("old"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: afterChunk.streamToken)
}
