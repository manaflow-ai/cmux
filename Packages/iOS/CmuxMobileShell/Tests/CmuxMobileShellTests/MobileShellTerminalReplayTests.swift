import Foundation
import Testing
@testable import CmuxMobileShell

/// A local Ghostty surface rebuild must actively request an authoritative
/// render-grid replay. Waiting for future deltas is not enough: a TUI may be
/// idle after reconnect, and the rebuilt phone-side surface would otherwise stay
/// behind the Mac's real terminal state.
@MainActor
@Test func explicitSurfaceReplayRequestRepaintsMountedSinkAfterLocalRebuild() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    try await router.setReplayFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "BEFORE"
    )
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let initialReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("BEFORE") }
    }
    #expect(initialReplayDelivered)

    try await router.setReplayFrame(
        surfaceID: "live-terminal",
        seq: 2,
        text: "AFTER-REBUILD"
    )
    let replayDeliveredToSink = await store.performTerminalReplay(surfaceID: "live-terminal")
    #expect(replayDeliveredToSink)

    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") >= 2
    }
    #expect(replayRequested)
    let rebuiltReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("AFTER-REBUILD") }
    }
    #expect(rebuiltReplayDelivered)
    collector.unmount()
}

@MainActor
@Test func terminalReplayReportsEmptyResponseAsNotDelivered() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sinkMounted = try await pollUntil {
        store.debugHasTerminalOutputSinkForTesting(surfaceID: "live-terminal")
    }
    #expect(sinkMounted)

    let delivered = await store.performTerminalReplay(surfaceID: "live-terminal")
    #expect(!delivered)
    collector.unmount()
}

@MainActor
@Test func terminalReplayJoinsExistingInFlightReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    try await router.setReplayFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "JOINED-REPLAY"
    )
    await router.holdReplayRequest(number: 1)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let firstReplayStarted = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") == 1
    }
    #expect(firstReplayStarted)

    let joinedReplay = Task { @MainActor in
        await store.performTerminalReplay(surfaceID: "live-terminal")
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(await router.count(of: "mobile.terminal.replay") == 1)
    await router.releaseAllHeld()

    let delivered = await joinedReplay.value
    #expect(delivered)
    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("JOINED-REPLAY") }
    }
    #expect(replayDelivered)
    collector.unmount()
}

@MainActor
@Test func orphanedTerminalReplayDoesNotClearNewerReplayTask() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    let box = TransportBox()
    try await router.setReplayFrame(
        surfaceID: "live-terminal",
        seq: 1,
        text: "ORPHANED-REPLAY"
    )
    await router.holdReplayRequest(number: 1)
    await router.holdReplayRequest(number: 2)
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    defer {
        Task { await router.releaseAllHeld() }
    }

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let firstReplayStarted = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") == 1
    }
    #expect(firstReplayStarted)
    #expect(store.terminalReplayRetryTaskIDsBySurfaceID["live-terminal"] != nil)

    store.terminalReplayRetryTasksBySurfaceID = [:]
    store.terminalReplayRetryTaskIDsBySurfaceID = [:]
    let newerReplay = Task { @MainActor in
        await store.performTerminalReplay(surfaceID: "live-terminal")
    }
    let secondReplayStarted = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") == 2
    }
    #expect(secondReplayStarted)
    let newerTaskID = try #require(store.terminalReplayRetryTaskIDsBySurfaceID["live-terminal"])

    await router.releaseHeldReplayRequest(number: 1)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(store.terminalReplayRetryTaskIDsBySurfaceID["live-terminal"] == newerTaskID)

    await router.releaseAllHeld()
    _ = await newerReplay.value
    collector.unmount()
}
