import CMUXMobileCore
import Foundation
import Testing
@testable import CmuxMobileShell

@Test func renderGridProcessorPreparesReplayAndEventBytes() async throws {
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: "terminal",
        stateSeq: 42,
        columns: 12,
        rows: 1,
        text: "prepared"
    )
    let frameObject = try frame.jsonObject()
    let tail = Data("tail".utf8)
    let snapshot = Data("snapshot".utf8)
    let replayData = try JSONSerialization.data(withJSONObject: [
        "data_b64": tail.base64EncodedString(),
        "snapshot_data_b64": snapshot.base64EncodedString(),
        "render_grid": frameObject,
        "seq": 41,
        "columns": 12,
        "rows": 1,
    ])
    let processor = TerminalRenderGridProcessor()

    let replay = await processor.processReplayResponse(
        data: replayData,
        expectedSurfaceID: "terminal"
    )
    #expect(replay.bytes == tail)
    #expect(replay.snapshotBytes == snapshot)
    #expect(replay.renderGrid?.frame == frame)
    #expect(replay.renderGrid?.bytes == frame.vtPatchBytes())

    let wrappedEventData = try JSONSerialization.data(withJSONObject: [
        "render_grid": frameObject,
    ])
    let wrappedEvent = await processor.processRenderGridEvent(data: wrappedEventData)
    #expect(wrappedEvent?.frame == frame)
    #expect(wrappedEvent?.bytes == frame.vtPatchBytes())

    let bareEventData = try JSONSerialization.data(withJSONObject: frameObject)
    let bareEvent = await processor.processRenderGridEvent(data: bareEventData)
    #expect(bareEvent == wrappedEvent)
}
