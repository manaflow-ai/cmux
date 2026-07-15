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

@MainActor
@Test func livenessRepairDeliversSameSeqReplayAfterExistingFullGrid() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let subscribed = try await pollUntil { await router.count(of: "mobile.events.subscribe") >= 1 }
    #expect(subscribed)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let mountReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(mountReplay)
    let mountReplayCompleted = try await pollUntil { await router.replayResponsesServed() >= 1 }
    #expect(mountReplayCompleted)
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 5,
        text: "stale-grid"
    ))
    let staleGridDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("stale-grid") }
    }
    #expect(staleGridDelivered)

    await router.dropSubscription()
    await router.enqueueReplayRenderGridFrames([
        try MobileTerminalRenderGridFrame(
            surfaceID: "live-terminal",
            stateSeq: 5,
            columns: 16,
            rows: 4,
            full: true,
            rowSpans: [.init(row: 0, column: 0, text: "fresh-grid")]
        ),
    ])
    let replayCountBeforeRepair = await router.count(of: "mobile.terminal.replay")
    clock.advance(by: 10)
    store.debugRunRenderGridLivenessCheckForTesting()

    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountBeforeRepair
    }
    #expect(replayRequested)
    let freshGridDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-grid") }
    }
    #expect(freshGridDelivered)
    collector.unmount()
}
