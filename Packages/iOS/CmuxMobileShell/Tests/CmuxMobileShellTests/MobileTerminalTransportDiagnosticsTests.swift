#if DEBUG
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test("terminal diagnostics follow queue drain and replay reset owners")
func terminalDiagnosticsFollowQueueDrainAndReplayResetOwners() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "diagnostics-terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    store.deliverTerminalBytes(Data("first".utf8), surfaceID: surfaceID)
    let first = try #require(await iterator.next())
    store.deliverTerminalBytes(Data("second".utf8), surfaceID: surfaceID)
    #expect(store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID).deliveryQueueDepth == 1)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: first.streamToken)
    let second = try #require(await iterator.next())
    #expect(store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID).deliveryQueueDepth == 0)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: second.streamToken)
    #expect(store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID).deliveryQueueDepth == 0)

    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let requestID = UUID()
    store.markTerminalReplayInFlight(
        surfaceID: surfaceID,
        requestID: requestID,
        replayBarrierToken: barrierToken
    )
    store.terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] = barrierToken
    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 77)

    let active = store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID)
    #expect(active.deliveryQueueDepth == 0)
    #expect(active.replayBarrierDepth == 1)
    #expect(active.replayInFlightDepth == 1)
    #expect(active.pendingViewportAckDepth == 1)
    #expect(active.deliveredEndSeq == 77)

    store.clearTerminalReplayInFlightIfCurrent(surfaceID: surfaceID, requestID: requestID)
    #expect(store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID).replayInFlightDepth == 0)
    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "diagnostics_test"
    ))

    let reset = store.mobileTerminalTransportDiagnostics(surfaceID: surfaceID)
    #expect(reset.deliveryQueueDepth == 0)
    #expect(reset.replayBarrierDepth == 0)
    #expect(reset.replayInFlightDepth == 0)
    #expect(reset.pendingViewportAckDepth == 0)
    #expect(reset.deliveredEndSeq == 77)
}
#endif
