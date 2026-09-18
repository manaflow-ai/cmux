import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

// Regression coverage for the input-echo liveness fast path (issue 10471,
// "input still reaches tmux but output stops rendering").
//
// The render-grid liveness watchdog treats wall-clock silence as its only
// suspicion signal, and its probe runs over the CONTROL channel. Two holes
// follow:
//
// 1. A typed input whose accepted-input watermark never comes back is
//    positive evidence the output path is stalled, yet the watchdog waited
//    for the full 9s ambient silence window before probing. A user typing
//    into a stalled terminal froze for 9-15s before recovery even started.
// 2. Worse, when the control channel stayed healthy while only the event
//    lane died, the probe SUCCEEDED, re-stamped the liveness clock, and
//    pacified the watchdog forever: the terminal stayed frozen until the
//    user backgrounded the app. Marked terminal input (#12816) breaks the
//    tie: an accepted input with no acknowledging output and no consumed
//    events since dispatch proves the silence is not "idle terminal".
//
// These tests drive the RPC input path; the fire-and-forget lane input path
// records the same pending-echo evidence at its send site.

private let inputEchoCapabilities = [
    "events.v1", "terminal.render_grid.v1", "terminal.replay.v1",
    MobileTerminalInputFrame.capability,
]

@MainActor
private func makeEchoTestStore(
    router: LivenessHostRouter,
    box: TransportBox,
    clock: TestClock
) async throws -> MobileShellComposite {
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let sawSubscribe = try await pollUntil {
        await router.count(of: "mobile.events.subscribe") >= 1
    }
    #expect(sawSubscribe, "listener must establish the push subscription")
    return store
}

/// Mounts the fixture surface and settles its cold-attach replay plus one
/// delivered baseline frame, so the consumed-event clock has a real stamp
/// that predates the typed input under test.
@MainActor
private func mountBaselinedSurface(
    store: MobileShellComposite,
    router: LivenessHostRouter,
    box: TransportBox,
    collector: OutputCollector
) async throws {
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawMountReplay = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 1
    }
    #expect(sawMountReplay, "mounting a sink arms exactly one cold-attach replay")
    try await waitForReplayResponsesServed(
        1,
        router: router,
        "the cold replay response must settle before testing echo liveness"
    )
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "baseline",
        activeScreen: .alternate
    ))
    let baselineDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("baseline") }
    }
    #expect(baselineDelivered, "the baseline frame must be consumed before typing")
}

/// Issue 10471: the control channel answers the probe while the event lane is
/// dead. A marked input past the echo threshold must first pull the probe in
/// ahead of the ambient 9s window, and a SUCCESSFUL probe must then repair the
/// output path (replay the mounted surfaces) instead of being pacified.
@MainActor
@Test func typedInputWithoutEchoRepairsStalledOutputPathDespiteHealthyProbe() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(inputEchoCapabilities)
    // terminal_seq 0 keeps the RPC-ack catch-up machinery (input_seq_wait)
    // disarmed, isolating the echo-stall path this test covers.
    await router.enqueueTerminalInputSequences([0])
    let box = TransportBox()
    let store = try await makeEchoTestStore(router: router, box: box, clock: clock)
    defer { Task { await router.releaseAllHeld() } }
    let collector = OutputCollector()
    try await mountBaselinedSurface(store: store, router: router, box: box, collector: collector)
    let originalClient = try #require(store.remoteClient)
    let originalGeneration = store.connectionGeneration

    clock.advance(by: 1)
    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let inputAccepted = try await pollUntil {
        await router.count(of: "terminal.input") >= 1
    }
    #expect(inputAccepted, "the host must accept the marked input")
    let replayCountBeforeStall = await router.count(of: "mobile.terminal.replay")

    // 3s after typing: far past the 2s echo threshold, far short of the 9s
    // ambient silence window. Today's watchdog does nothing here.
    clock.advance(by: 3)
    store.debugRunRenderGridLivenessCheckForTesting()
    let probed = await router.waitForCount(of: "mobile.events.probe", atLeast: 1)
    #expect(
        probed,
        "an unacknowledged marked input past the echo threshold must probe before the ambient silence window"
    )

    // The probe succeeds (registration intact), yet the echo is still
    // missing: the watchdog must repair the output path, not record the
    // probe round-trip as liveness and go back to sleep.
    let repaired = try await pollUntil(attempts: 600) {
        store.debugRunRenderGridLivenessCheckForTesting()
        return await router.count(of: "mobile.terminal.replay") >= replayCountBeforeStall + 1
    }
    #expect(
        repaired,
        "a successful probe must not pacify the watchdog while a marked input has no acknowledging output (issue 10471)"
    )
    #expect(store.remoteClient === originalClient, "output-path repair must not replace the session")
    #expect(store.connectionGeneration == originalGeneration)
    #expect(store.connectionState == .connected)
}

/// False-positive guard: output that keeps flowing after the typed input
/// proves the stream is alive even when nothing acknowledges the marker (a
/// program with echo off, e.g. a password prompt). No early probe may fire.
@MainActor
@Test func outputFlowAfterTypedInputKeepsEchoWatchdogQuiet() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(inputEchoCapabilities)
    await router.enqueueTerminalInputSequences([0])
    let box = TransportBox()
    let store = try await makeEchoTestStore(router: router, box: box, clock: clock)
    defer { Task { await router.releaseAllHeld() } }
    let collector = OutputCollector()
    try await mountBaselinedSurface(store: store, router: router, box: box, collector: collector)

    clock.advance(by: 1)
    await store.submitTerminalRawInput(Data("s".utf8), surfaceID: "live-terminal")
    let inputAccepted = try await pollUntil {
        await router.count(of: "terminal.input") >= 1
    }
    #expect(inputAccepted)

    // Later output WITHOUT a watermark (no applied_input_sequence): the
    // program prints while never echoing the marker.
    clock.advance(by: 1)
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 2,
        text: "unrelated-output",
        activeScreen: .alternate
    ))
    let outputDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("unrelated-output") }
    }
    #expect(outputDelivered)

    clock.advance(by: 3)
    store.debugRunRenderGridLivenessCheckForTesting()
    // Give a wrongly-armed probe a real-time window to surface before
    // asserting quiet.
    _ = await router.waitForCount(
        of: "mobile.events.probe",
        atLeast: 1,
        timeoutNanoseconds: 300_000_000,
        recordIssueOnTimeout: false
    )
    #expect(
        await router.count(of: "mobile.events.probe") == 0,
        "output consumed after the typed input proves the stream is alive; the echo fast path must stay quiet"
    )
}

/// Hosts without `terminal.input.latency.v1` send no markers, so typed input
/// provides no echo evidence: the watchdog must keep today's ambient-silence
/// behavior and not probe early.
@MainActor
@Test func unmarkedInputDoesNotArmEchoWatchdog() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    // Default capabilities: no input-latency marker support.
    await router.enqueueTerminalInputSequences([0])
    let box = TransportBox()
    let store = try await makeEchoTestStore(router: router, box: box, clock: clock)
    defer { Task { await router.releaseAllHeld() } }
    let collector = OutputCollector()
    try await mountBaselinedSurface(store: store, router: router, box: box, collector: collector)

    clock.advance(by: 1)
    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let inputAccepted = try await pollUntil {
        await router.count(of: "terminal.input") >= 1
    }
    #expect(inputAccepted)

    clock.advance(by: 3)
    store.debugRunRenderGridLivenessCheckForTesting()
    _ = await router.waitForCount(
        of: "mobile.events.probe",
        atLeast: 1,
        timeoutNanoseconds: 300_000_000,
        recordIssueOnTimeout: false
    )
    #expect(
        await router.count(of: "mobile.events.probe") == 0,
        "without markers there is no echo evidence; the ambient window governs"
    )
}

/// With echo-stall evidence, one failed probe is enough: the terminal is
/// provably not idle, so the two-failure confirmation (built for ambiguous
/// ambient silence) must not add another 2.5-5.5s to the user's freeze.
@MainActor
@Test func stalledInputEchoEscalatesAfterSingleFailedProbe() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(inputEchoCapabilities)
    await router.enqueueTerminalInputSequences([0])
    let box = TransportBox()
    let store = try await makeEchoTestStore(router: router, box: box, clock: clock)
    defer { Task { await router.releaseAllHeld() } }
    let collector = OutputCollector()
    try await mountBaselinedSurface(store: store, router: router, box: box, collector: collector)
    let originalClient = try #require(store.remoteClient)
    let subscribeCountBefore = await router.count(of: "mobile.events.subscribe")

    clock.advance(by: 1)
    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let inputAccepted = try await pollUntil {
        await router.count(of: "terminal.input") >= 1
    }
    #expect(inputAccepted)

    // The single held probe times out; no second probe may be required.
    await router.holdProbeRequest(number: 1)
    clock.advance(by: 3)
    store.debugRunRenderGridLivenessCheckForTesting()
    #expect(await router.waitForCount(of: "mobile.events.probe", atLeast: 1))

    let repaired = try await pollUntil(attempts: 600) {
        store.debugRunRenderGridLivenessCheckForTesting()
        return await router.count(of: "mobile.events.subscribe") >= subscribeCountBefore + 1
    }
    #expect(
        repaired,
        "echo-stall evidence plus one failed probe must start recovery without waiting for a second failure"
    )
    #expect(
        await router.count(of: "mobile.events.probe") == 1,
        "recovery must not wait for a second probe when the terminal is provably not idle"
    )
    #expect(store.remoteClient === originalClient, "a live transport repairs the event lane in place")
    #expect(store.connectionState == .connected)
}
