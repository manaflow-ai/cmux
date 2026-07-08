import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

/// Regression coverage for stall recovery fidelity around resets and replays:
/// a successful missing-baseline replay must resolve the baseline_wait gate
/// episode, and reset paths that leave a replay barrier gating output must
/// not claim recovery (https://github.com/manaflow-ai/cmux/issues/7573
/// review rounds).

@MainActor
@Test func ackResetRetryResolvesOnlyGatesTheResetActuallyWipes() async throws {
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
    let iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    _ = iterator
    let barrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .baselineWait,
        droppedFrames: 1,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))
    store.terminalSyncDiagnostics.renderGridDropped(
        surface: surfaceHandle,
        gate: .baselineWait,
        droppedFrames: 2,
        replayRetryCount: 0,
        barrierFollowUpCount: 0,
        transport: "renderGrid"
    )
    #expect(analytics.events(named: "ios_terminal_render_stall").count == 2)

    // The reset arrives on a stream token that carried the barrier ack, but
    // the retry keeps the SAME barrier armed (retry budget exhausted so the
    // barrier is preserved). Only the wiped gates may resolve.
    let streamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    store.terminalReplayBarrierAckStreamTokensBySurfaceID[surfaceID] = streamToken
    store.terminalReplayFailureRetryCountsBySurfaceID[surfaceID] = MobileShellComposite.maxTerminalReplayFailureRetries
    store.terminalOutputDidReset(surfaceID: surfaceID, streamToken: streamToken)

    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)
    let recovered = analytics.events(named: "ios_terminal_render_stall_recovered")
    #expect(recovered.count == 1)
    #expect(recovered.first?["gate"] == .string("baseline_wait"))
    #expect(recovered.first?["recovery"] == .string("manual_refresh"))
}

@MainActor
@Test func needsReplayWithPendingViewportAckDoesNotClaimStallRecovery() async throws {
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
    store.terminalViewportReplayBarrierPendingAckTokensBySurfaceID[surfaceID] = barrierToken
    #expect(!store.deliverTerminalBytes(Data("drop-1".utf8), surfaceID: surfaceID))
    clock.advance(by: 6)
    #expect(!store.deliverTerminalBytes(Data("drop-2".utf8), surfaceID: surfaceID))
    #expect(analytics.events(named: "ios_terminal_render_stall").count == 1)

    store.terminalOutputNeedsReplay(surfaceID: surfaceID)

    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == barrierToken)
    #expect(analytics.events(named: "ios_terminal_render_stall_recovered").isEmpty)
    #expect(analytics.events(named: "ios_terminal_manual_recovery").count == 1)
}

@MainActor
@Test func baselineReplaySuccessResolvesBaselineWaitStall() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let analytics = RecordingFreezeAnalytics()
    let runtime = LivenessTestRuntime(
        transportFactory: LivenessTransportFactory(router: router, box: box),
        now: { clock.now },
        livenessProbeTimeoutNanoseconds: 200_000_000
    )
    let store = MobileShellComposite(
        runtime: runtime,
        workspaces: PreviewMobileHost.workspaces,
        deliveredNotificationClearer: NoopDeliveredNotificationClearer(),
        analytics: analytics
    )
    store.signIn()
    let ticket = try makeTicket(clock: clock)
    let connected = await store.connectPairingURL(try attachURL(for: ticket))
    #expect(connected, "scripted connect must succeed")
    let capabilitiesResolved = try await pollUntil {
        !store.supportedHostCapabilities.isEmpty
    }
    #expect(capabilitiesResolved)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    // Two baseline-wait drops more than the stall threshold apart open a
    // detected baseline_wait episode while the missing-baseline replay is
    // held in flight.
    await router.holdNextReplayResponses()
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-before-baseline",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    clock.advance(by: 6)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "second-partial-before-baseline",
        full: false
    ))
    let stalled = try await pollUntil {
        analytics.events(named: "ios_terminal_render_stall").contains {
            $0["gate"] == .string("baseline_wait")
        }
    }
    #expect(stalled, "a second baseline-wait drop past the threshold must emit a stall")

    // The missing-baseline replay succeeds with a full frame; delivering it
    // establishes the baseline and must resolve the baseline_wait stall.
    await router.enqueueReplayRenderGrid(try renderGridFrame(
        surfaceID: surfaceID,
        seq: 6,
        text: "authoritative-baseline",
        full: true
    ))
    await router.releaseAllHeld()
    let replayChunk = try #require(await iterator.next())
    #expect(String(decoding: replayChunk.data, as: UTF8.self).contains("authoritative-baseline"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: replayChunk.streamToken)

    let recovered = try await pollUntil {
        analytics.events(named: "ios_terminal_render_stall_recovered").contains {
            $0["gate"] == .string("baseline_wait") && $0["recovery"] == .string("replay_ack")
        }
    }
    #expect(recovered, "baseline replay success must resolve the baseline_wait stall as replay_ack")
}
