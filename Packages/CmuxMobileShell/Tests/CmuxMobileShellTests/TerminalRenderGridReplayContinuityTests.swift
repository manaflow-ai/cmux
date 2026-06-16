import CMUXMobileCore
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func failedReplayLeavesContinuityGapUntilFullRenderGrid() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    let replayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 2,
        columns: 16,
        rows: 2,
        text: "live\nviewport",
        full: false,
        changedRows: [0, 1]
    )
    store.deliverAuthoritativeTerminalRenderGrid(liveFrame, source: "event")
    store.debugFailTerminalReplayForTesting(surfaceID: surfaceID, replayID: replayID)

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let partialAfterFailure = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 3,
        columns: 16,
        rows: 2,
        text: "partial after failure\nviewport",
        full: false,
        changedRows: [0]
    )
    store.deliverAuthoritativeTerminalRenderGrid(partialAfterFailure, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let fullAfterFailure = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 4,
        columns: 16,
        rows: 2,
        text: "full after failure\nviewport",
        full: true
    )
    store.deliverAuthoritativeTerminalRenderGrid(fullAfterFailure, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID) == false)
}

@MainActor
@Test func sequenceOnlyReplayLeavesContinuityGapUntilFullRenderGrid() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    let replayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let liveFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 6,
        columns: 16,
        rows: 2,
        text: "live\nviewport",
        full: false,
        changedRows: [0, 1]
    )
    store.deliverAuthoritativeTerminalRenderGrid(liveFrame, source: "event")

    try store.debugApplyTerminalReplayResponseForTesting(
        surfaceID: surfaceID,
        replayID: replayID,
        data: Data(#"{"seq":5}"#.utf8)
    )

    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil)
    #expect(store.terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let partialAfterSequenceOnly = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 7,
        columns: 16,
        rows: 2,
        text: "partial after sequence-only\nviewport",
        full: false,
        changedRows: [0]
    )
    store.deliverAuthoritativeTerminalRenderGrid(partialAfterSequenceOnly, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let fullAfterSequenceOnly = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 8,
        columns: 16,
        rows: 2,
        text: "full after sequence-only\nviewport",
        full: true
    )
    store.deliverAuthoritativeTerminalRenderGrid(fullAfterSequenceOnly, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID) == false)
}

@MainActor
@Test func failedReplayRecoversFromBufferedFullRenderGrid() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    let replayID = store.debugMarkTerminalReplayInFlightForTesting(surfaceID: surfaceID)
    let partialBeforeFull = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 6,
        columns: 16,
        rows: 2,
        text: "partial before full\nviewport",
        full: false,
        changedRows: [0]
    )
    let fullFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 7,
        columns: 16,
        rows: 2,
        text: "buffered full\nviewport",
        full: true
    )
    let partialAfterFull = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 8,
        columns: 16,
        rows: 2,
        text: "partial after full\nviewport",
        full: false,
        changedRows: [1]
    )

    store.deliverAuthoritativeTerminalRenderGrid(partialBeforeFull, source: "event")
    store.deliverAuthoritativeTerminalRenderGrid(fullFrame, source: "event")
    store.deliverAuthoritativeTerminalRenderGrid(partialAfterFull, source: "event")
    store.debugFailTerminalReplayForTesting(surfaceID: surfaceID, replayID: replayID)

    let queueAfterRecovery = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterRecovery.isIdle == false)
    #expect(queueAfterRecovery.pendingCount == 1)
    #expect(store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 8)
    #expect(store.terminalReplayIDsInFlightBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridFramesBufferedDuringReplayBySurfaceID[surfaceID] == nil)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID) == false)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)
    let queueAfterFullAck = try #require(store.terminalOutputQueuesBySurfaceID[surfaceID])
    #expect(queueAfterFullAck.isIdle == false)
    #expect(queueAfterFullAck.pendingCount == 0)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
}

@MainActor
@Test func staleFullRenderGridDoesNotClearContinuityGap() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    let streamToken = UUID()
    let stream = AsyncStream<MobileTerminalOutputChunk> { continuation in
        store.terminalByteContinuationsBySurfaceID[surfaceID] = continuation
        store.terminalOutputStreamTokensBySurfaceID[surfaceID] = streamToken
        store.terminalOutputQueuesBySurfaceID[surfaceID] = TerminalOutputDeliveryQueue()
    }
    _ = stream

    store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] = 10
    store.terminalRenderGridContinuityGapSurfaceIDs.insert(surfaceID)

    let staleFullFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 9,
        columns: 16,
        rows: 2,
        text: "stale full\nviewport",
        full: true
    )
    store.deliverAuthoritativeTerminalRenderGrid(staleFullFrame, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let partialAfterStaleFull = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 11,
        columns: 16,
        rows: 2,
        text: "partial after stale full\nviewport",
        full: false,
        changedRows: [0]
    )
    store.deliverAuthoritativeTerminalRenderGrid(partialAfterStaleFull, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID))

    let freshFullFrame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 12,
        columns: 16,
        rows: 2,
        text: "fresh full\nviewport",
        full: true
    )
    store.deliverAuthoritativeTerminalRenderGrid(freshFullFrame, source: "event")
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == false)
    #expect(store.terminalRenderGridContinuityGapSurfaceIDs.contains(surfaceID) == false)
}
