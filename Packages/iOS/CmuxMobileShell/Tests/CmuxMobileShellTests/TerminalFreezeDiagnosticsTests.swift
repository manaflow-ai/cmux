import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func replayBarrierDropEmitsStallAndRecoveryDiagnostics() async throws {
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let diagnosticLog = DiagnosticLog(capacity: 64)
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics,
        diagnosticLog: diagnosticLog
    )

    let surfaceID = "live-terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))

    let stallEvents = analytics.events(named: "ios_terminal_render_stall")
    #expect(stallEvents.count == 1)
    #expect(stallEvents.first?["gate"] == .string("replay_barrier"))
    #expect(stallEvents.first?["dropped_frame_count"] == .int(2))

    let accepted = store.deliverTerminalBytes(
        Data("fresh".utf8),
        surfaceID: surfaceID,
        bypassReplayBarrier: true
    )
    #expect(accepted)
    let recoveryChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: recoveryChunk.streamToken)

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["recovery"] == .string("replay_ack"))

    await waitForDiagnosticEvents(diagnosticLog, atLeast: 5)
    let export = String(decoding: await diagnosticLog.export(), as: UTF8.self)
    #expect(export.contains(",25,"))
    #expect(export.contains(",26,"))
    #expect(export.contains(",27,"))
    #expect(export.contains(",32,"))
    #expect(export.contains(",33,"))
}

@MainActor
@Test func nonUTF8RawInputEmitsExistingDroppedInputEventWithReason() async throws {
    let analytics = RecordingFreezeAnalytics()
    let diagnosticLog = DiagnosticLog(capacity: 64)
    let store = MobileShellComposite(
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics,
        diagnosticLog: diagnosticLog
    )

    await store.submitTerminalRawInput(Data([0xff, 0xfe]), surfaceID: "live-terminal")

    let dropped = analytics.events(named: "ios_terminal_input_dropped")
    #expect(dropped.count == 1)
    #expect(dropped.first?["reason"] == .string("non_utf8"))
    #expect(dropped.first?["pending_byte_count"] == nil)

    await waitForDiagnosticEvents(diagnosticLog, atLeast: 1)
    let rows = diagnosticRows(await diagnosticLog.export())
    let inputDropRows = rows.filter { diagnosticColumn($0, 1) == "46" }
    #expect(inputDropRows.count == 1)
    #expect(inputDropRows.first.map { diagnosticColumn($0, 4) } == "2")
    #expect(inputDropRows.first.map { diagnosticColumn($0, 5) } == "")
}

@MainActor
@Test func replayBarrierFailureClearDoesNotRecoverAsReplayAck() async throws {
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let diagnosticLog = DiagnosticLog(capacity: 64)
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: LivenessHostRouter(), box: TransportBox()),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
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

    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "empty"
    ))

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["gate"] == .string("replay_barrier"))
    #expect(recoveredEvents.first?["recovery"] == .string("barrier_cleared"))
    #expect(recoveredEvents.first?["recovery"] != .string("replay_ack"))

    await waitForDiagnosticEvents(diagnosticLog, atLeast: 5)
    let rows = diagnosticRows(await diagnosticLog.export())
    let recoveryRows = rows.filter { diagnosticColumn($0, 1) == "26" }
    #expect(recoveryRows.count == 1)
    #expect(recoveryRows.first.map { diagnosticColumn($0, 5) } == "7")
}

@MainActor
@Test func programmaticWorkspaceMutationRefreshDoesNotEmitManualRecovery() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let store = try await makeConnectedFreezeDiagnosticsStore(
        router: router,
        box: box,
        clock: clock,
        analytics: analytics
    )
    let target = WorkspaceMutationTarget(
        client: store.remoteClient,
        isForeground: true,
        macDeviceID: store.foregroundMacDeviceID
    )

    await store.refreshAfterWorkspaceMutation(target)

    #expect(analytics.events(named: "ios_terminal_manual_recovery").isEmpty)
}

@MainActor
@Test func viewportOwnedPreservedBarrierEmitsLeakedPreservedAnalyticsOnlyOnce() async throws {
    let analytics = RecordingFreezeAnalytics()
    let diagnosticLog = DiagnosticLog(capacity: 64)
    let store = MobileShellComposite(
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics,
        diagnosticLog: diagnosticLog
    )
    let surfaceID = "live-terminal"
    let token = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    store.terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] = token

    #expect(store.preserveTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: token,
        reason: "failed"
    ))

    let viewportEvents = analytics.events(named: "ios_terminal_viewport_barrier")
    #expect(viewportEvents.count == 1)
    #expect(viewportEvents.first?["outcome"] == .string("leaked_preserved"))

    await waitForDiagnosticEvents(diagnosticLog, atLeast: 2)
    let rows = diagnosticRows(await diagnosticLog.export())
    let preservedRows = rows.filter { diagnosticColumn($0, 1) == "34" }
    #expect(preservedRows.count == 1)
    #expect(preservedRows.first.map { diagnosticColumn($0, 4) } == "15")
    let leakedRows = rows.filter { diagnosticColumn($0, 1) == "45" }
    #expect(leakedRows.count == 1)
    #expect(leakedRows.first.map { diagnosticColumn($0, 4) } == "3")
}

@MainActor
@Test func seqGapResyncUsesSequenceContinuityTrigger() async throws {
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

    store.resyncTerminalOutput(reason: "seq_gap", restartEventStream: false, surfaceIDs: ["live-terminal"])

    let resyncEvents = analytics.events(named: "ios_terminal_resync")
    #expect(resyncEvents.last?["trigger"] == .string("input_seq_behind"))

    await waitForDiagnosticEvents(diagnosticLog, atLeast: 1)
    let rows = diagnosticRows(await diagnosticLog.export())
    let resyncRows = rows.filter { diagnosticColumn($0, 1) == "41" }
    #expect(resyncRows.last.map { diagnosticColumn($0, 4) } == "5")
}

@MainActor
@Test func appliedFrameDoesNotResolveStillArmedReplayBarrier() async throws {
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

    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 42)

    #expect(analytics.events(named: "ios_terminal_render_stall").count == 1)
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").isEmpty)

    #expect(store.clearTerminalReplayBarrierIfCurrent(
        surfaceID: surfaceID,
        token: barrierToken,
        reason: "empty"
    ))
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").count == 1)
}

@MainActor
@Test func inputSeqCatchUpResolvesOnlyPendingInputGate() async throws {
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
        gate: .pendingInputSeq,
        droppedFrames: 2,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .replayBarrier,
        droppedFrames: 2,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    store.pendingTerminalByteEndSeqBySurfaceID[surfaceID] = 20

    store.markTerminalBytesDelivered(surfaceID: surfaceID, endSeq: 20)

    let recoveredEvents = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recoveredEvents.count == 1)
    #expect(recoveredEvents.first?["gate"] == .string("pending_input_seq"))
    #expect(recoveredEvents.first?["recovery"] == .string("catchup_frame"))
}

@MainActor
@Test func resetWithStillActiveBarrierDoesNotClaimStallRecovery() async throws {
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
    let iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    _ = iterator
    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))
    #expect(analytics.events(named: "ios_terminal_render_stall").count == 1)

    // A render-pipeline reset while the barrier still gates output (the
    // stream token never carried a barrier ack) must not close the episode:
    // the terminal is still frozen behind the same barrier.
    let streamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: streamToken)

    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").isEmpty)
}

@MainActor
@Test func cancelledViewportReportCapturesBarrierOutcomeAnalytics() async throws {
    let analytics = RecordingFreezeAnalytics()
    let store = MobileShellComposite(
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics
    )

    store.terminalViewportReportCancelled(surfaceID: "live-terminal")

    let viewportEvents = analytics.events(named: "ios_terminal_viewport_barrier")
    #expect(viewportEvents.count == 1)
    #expect(viewportEvents.first?["outcome"] == .string("cancelled_superseded"))
}

final class RecordingFreezeAnalytics: AnalyticsEmitting, @unchecked Sendable {
    private var recorded: [(name: String, properties: [String: AnalyticsValue])] = []

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        recorded.append((event, properties))
    }

    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}

    func setSuperProperties(_ properties: [String: AnalyticsValue]) {}

    func flush() async {}

    func events(named name: String) -> [[String: AnalyticsValue]] {
        recorded.compactMap { event, properties in
            event == name ? properties : nil
        }
    }
}

private func waitForDiagnosticEvents(_ log: DiagnosticLog, atLeast count: Int) async {
    for _ in 0..<1_000_000 {
        if await log.processedCount() >= count { return }
        await Task.yield()
    }
}

@MainActor
func makeConnectedFreezeDiagnosticsStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock,
    analytics: RecordingFreezeAnalytics,
    diagnosticLog: DiagnosticLog? = nil
) async throws -> MobileShellComposite {
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now }
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics,
        diagnosticLog: diagnosticLog
    )
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    let capabilitiesResolved = try await pollUntil {
        !store.supportedHostCapabilities.isEmpty
    }
    #expect(capabilitiesResolved, "scripted connect must resolve host capabilities")
    return store
}

private func diagnosticRows(_ export: Data) -> [String] {
    String(decoding: export, as: UTF8.self)
        .split(separator: "\n", omittingEmptySubsequences: false)
        .dropFirst()
        .filter { !$0.isEmpty }
        .map(String.init)
}

private func diagnosticColumn(_ row: String, _ index: Int) -> String {
    let columns = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    guard columns.indices.contains(index) else { return "" }
    return columns[index]
}
