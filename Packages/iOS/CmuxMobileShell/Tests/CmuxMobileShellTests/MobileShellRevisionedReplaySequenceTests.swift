import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Test func revisionedReplayBelowDeliveredSequenceRequiresExplicitBarrier() async throws {
    let store = MobileShellComposite.preview()
    store.terminalOutputTransport = .renderGrid
    let surfaceID = "revisioned-replay-sequence"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let live = try replayFrame(
        surfaceID: surfaceID,
        sequence: 20,
        revision: 4,
        text: "newer-live"
    )
    #expect(store.deliverAuthoritativeTerminalRenderGrid(live, source: "event"))
    let liveChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)

    let staleReplay = try replayFrame(
        surfaceID: surfaceID,
        sequence: 10,
        revision: 5,
        text: "older-replay"
    )
    #expect(store.deliverAuthoritativeTerminalRenderGrid(staleReplay, source: "replay") == false)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 20)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 4)
}

@MainActor
@Test func revisionedReplayBelowDeliveredSequenceCanRebaseThroughExplicitBarrier() async throws {
    let store = MobileShellComposite.preview()
    store.terminalOutputTransport = .renderGrid
    let surfaceID = "revisioned-replay-barrier"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let live = try replayFrame(
        surfaceID: surfaceID,
        sequence: 20,
        revision: 4,
        text: "newer-live"
    )
    #expect(store.deliverAuthoritativeTerminalRenderGrid(live, source: "event"))
    let liveChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: liveChunk.streamToken)

    _ = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let resetReplay = try replayFrame(
        surfaceID: surfaceID,
        sequence: 10,
        revision: 5,
        text: "reset-replay"
    )
    #expect(store.deliverAuthoritativeTerminalRenderGrid(
        resetReplay,
        source: "replay",
        bypassReplayBarrier: true
    ))
    let replayChunk = try #require(await iterator.next())
    #expect(String(decoding: replayChunk.data, as: UTF8.self).contains("reset-replay"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 10)
}

private func replayFrame(
    surfaceID: String,
    sequence: UInt64,
    revision: UInt64,
    text: String
) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: sequence,
        renderRevision: revision,
        columns: 24,
        rows: 2,
        text: "\(text)\nrow"
    )
}
