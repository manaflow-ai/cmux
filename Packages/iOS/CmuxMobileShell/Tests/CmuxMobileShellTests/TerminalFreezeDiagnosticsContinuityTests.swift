import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func streamEndedRecordOnlyDoesNotAttributeLaterBarrierClearToResync() async throws {
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics
    )

    let surfaceID = "live-terminal"
    let outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    _ = outputIterator
    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))

    store.terminalSyncDiagnostics.resyncTriggered(
        trigger: .streamEnded,
        restartedStream: true,
        surfaceCount: 1
    )

    #expect(analytics.events(named: "ios_terminal_resync").last?["trigger"] == .string("stream_ended"))
    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "empty"
    ))

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["recovery"] == .string("barrier_cleared"))
    #expect(recoveredEvents.first?["recovery"] != .string("resync"))
}

@MainActor
@Test func pendingInputEpisodeTransfersToReplayBarrierUntilRealClear() async throws {
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics
    )

    let surfaceID = "live-terminal"
    let surfaceHandle = MobileShellComposite.diagnosticSurfaceHandle(surfaceID)
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .pendingInputSeq,
        droppedFrames: 1,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    clock.advance(by: 6)
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .pendingInputSeq,
        droppedFrames: 2,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )

    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(analytics.events(named: "ios_terminal_render_stall").count == 1)
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").isEmpty)

    clock.advance(by: 2)
    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "empty"
    ))

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["gate"] == .string("replay_barrier"))
    #expect(recoveredEvents.first?["recovery"] == .string("barrier_cleared"))
    #expect(recoveredEvents.first?["stall_duration_ms"] == .int(8000))
    #expect(recoveredEvents.first?["dropped_frame_count"] == .int(2))
}

@MainActor
@Test func resyncTriggerWaitsForActualGateClearAndAttributesRecovery() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let diagnosticLog = DiagnosticLog(capacity: 64)
    let store = try await makeConnectedFreezeDiagnosticsStore(
        router: router,
        box: box,
        clock: clock,
        analytics: analytics,
        diagnosticLog: diagnosticLog
    )

    let surfaceID = "live-terminal"
    let outputIterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    _ = outputIterator
    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))

    store.resyncTerminalOutput(reason: "liveness", restartEventStream: false, surfaceIDs: [surfaceID])

    #expect(analytics.events(named: "ios_terminal_resync").last?["trigger"] == .string("liveness"))
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").isEmpty)

    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "empty"
    ))

    // The drop already put a replay for this barrier in flight, so the
    // resync's own request was deduped and never started work; attribution
    // must not label the eventual clear as a resync recovery.
    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["gate"] == .string("replay_barrier"))
    #expect(recoveredEvents.first?["recovery"] == .string("barrier_cleared"))
}

@MainActor
@Test func acceptedResyncReplayRequestAttributesEventualRecovery() async throws {
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics
    )
    let surfaceHandle = MobileShellComposite.diagnosticSurfaceHandle("live-terminal")
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .replayBarrier,
        droppedFrames: 1,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    clock.advance(by: 6)
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .replayBarrier,
        droppedFrames: 2,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )

    // A replay request that actually passed the guards with the resync
    // trigger marks the open episodes, so the real gate clear reports
    // recovery=resync.
    store.terminalSyncDiagnostics.replayRequested(surface: surfaceHandle, trigger: .resync)
    store.terminalSyncDiagnostics.gateResolved(
        surface: surfaceHandle,
        gate: .replayBarrier,
        how: .replayAck,
        transport: "renderGrid"
    )

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["recovery"] == .string("resync"))
}
