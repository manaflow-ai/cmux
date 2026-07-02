import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func renderGridInputAcksDoNotReplayWhileWaitingForCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let subscribed = await router.waitForCount(of: "mobile.events.subscribe", atLeast: 1)
    #expect(subscribed, "connected render-grid transport must establish the event subscription")
    let subscribeCountAfterMount = await router.count(of: "mobile.events.subscribe")

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let firstInputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(firstInputSent)
    let firstRefreshSent = await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: subscribeCountAfterMount + 1
    )
    #expect(firstRefreshSent, "the first ahead-of-render-grid ACK should refresh the event subscription")
    let subscribeCountAfterFirstAck = await router.count(of: "mobile.events.subscribe")

    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(inputSent)
    let duplicateRefreshSent = await router.waitForCount(
        of: "mobile.events.subscribe",
        atLeast: subscribeCountAfterFirstAck + 1,
        timeoutNanoseconds: 500_000_000,
        recordIssueOnTimeout: false
    )
    #expect(
        !duplicateRefreshSent,
        "duplicate ACKs for the same pending sequence must not enqueue another subscription refresh"
    )

    let replayRequested = try await pollUntil(attempts: 50) {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(
        !replayRequested,
        "back-to-back input ACKs can legitimately run ahead of render-grid delivery; they must not force a full replay while waiting for the target frame"
    )
    collector.unmount()
}

@MainActor
@Test func renderGridInputPendingSequenceSkipsOlderFramesUntilTargetArrives() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(inputSent)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 99,
        text: "before-ack"
    ))
    let staleFrameDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("before-ack") }
    }
    #expect(
        !staleFrameDelivered,
        "once input ACKs establish a newer target sequence, an older render-grid cursor frame must not be presented and then corrected later"
    )

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "at-ack"
    ))
    let targetFrameDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("at-ack") }
    }
    #expect(targetFrameDelivered, "the first frame at the pending input sequence must render immediately")
    collector.unmount()
}

@MainActor
@Test func staleRenderGridFramesDoNotPoisonPendingInputCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let transport = try #require(box.get())

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 99,
        text: "baseline"
    ))
    let baselineDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("baseline") }
    }
    #expect(baselineDelivered)

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)
    let replayCountAfterInput = await router.count(of: "mobile.terminal.replay")

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 98,
        text: "older-than-delivered",
        columns: 40,
        full: false
    ))
    let staleFrameDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("older-than-delivered") }
    }
    #expect(!staleFrameDelivered)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "target-delta",
        full: false
    ))
    let targetFrameDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("target-delta") }
    }
    #expect(
        targetFrameDelivered,
        "stale frames older than the delivered sequence must not mark delta continuity unsafe"
    )
    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterInput + 1,
        timeoutNanoseconds: 500_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayRequested, "accepted target deltas must not force a replay after a stale frame")
    collector.unmount()
}

@MainActor
@Test func renderGridInputPendingSequenceRequiresReplayAfterDroppedDelta() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 99,
        text: "dropped-delta",
        full: false
    ))
    let staleFrameDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("dropped-delta") }
    }
    #expect(!staleFrameDelivered)

    try await router.enqueueReplayRenderGridFrames([
        renderGridFrame(surfaceID: "live-terminal", seq: 100, text: "replayed-target"),
    ])
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "incomplete-target",
        columns: 40,
        full: false
    ))
    let incompleteTargetDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("incomplete-target") }
    }
    #expect(!incompleteTargetDelivered)
    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 1
    )
    #expect(replayRequested)
    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("replayed-target") }
    }
    #expect(replayDelivered)
    collector.unmount()
}

@MainActor
@Test func renderGridInputPendingSequenceRequestsReplayAfterDroppedFrameAndRepeatedAck() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: "live-terminal")
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: "live-terminal")
    let firstInputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(firstInputSent)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 99,
        text: "missed-target"
    ))
    let staleFrameDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("missed-target") }
    }
    #expect(!staleFrameDelivered)

    await router.holdNextReplayResponses()
    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let secondInputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(secondInputSent)
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(replayRequested, "a pending input target that survived a dropped frame and another ACK must request replay")
    await transport.deliver(try renderGridEventFrame(
        surfaceID: "live-terminal",
        seq: 100,
        text: "incomplete-while-replay",
        columns: 40,
        full: false
    ))
    let incompleteTargetDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("incomplete-while-replay") }
    }
    #expect(!incompleteTargetDelivered)
    try await router.enqueueReplayRenderGridFrames([
        renderGridFrame(surfaceID: "live-terminal", seq: 100, text: "replayed-after-repeat"),
    ])
    await router.releaseAllHeld()
    let replayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("replayed-after-repeat") }
    }
    #expect(replayDelivered)
    collector.unmount()
}

@MainActor
@Test func renderGridReplayBehindPendingInputRequestsBarrierRetryAfterDroppedOutput() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let surfaceID = "live-terminal"
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")

    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let droppedOutputAccepted = store.deliverTerminalBytes(Data("live-during-barrier".utf8), surfaceID: surfaceID)
    #expect(!droppedOutputAccepted)
    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: surfaceID)
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)

    try await router.enqueueReplayRenderGridFrames([
        renderGridFrame(surfaceID: surfaceID, seq: 99, text: "stale-replay"),
        renderGridFrame(surfaceID: surfaceID, seq: 100, text: "fresh-replay"),
    ])
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 1)
    let retryRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 2,
        recordIssueOnTimeout: false
    )
    #expect(retryRequested, "a replay dropped behind pending input must request a replacement while the barrier is preserved")
    let freshReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-replay") }
    }
    #expect(freshReplayDelivered)
    collector.unmount()
}

@MainActor
@Test func renderGridReplayBehindPendingInputRetriesNonBarrierReplay() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let surfaceID = "live-terminal"
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let mountReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(mountReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await router.holdNextReplayResponses()
    store.requestTerminalReplay(surfaceID: surfaceID)
    let oldReplayInFlight = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 1
    )
    #expect(oldReplayInFlight)

    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: surfaceID)
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 99,
        text: "dropped-event-delta",
        columns: 40,
        full: false
    ))
    let droppedDeltaDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("dropped-event-delta") }
    }
    #expect(!droppedDeltaDelivered)

    try await router.enqueueReplayRenderGridFrames([
        renderGridFrame(surfaceID: surfaceID, seq: 99, text: "stale-nonbarrier-replay"),
        renderGridFrame(surfaceID: surfaceID, seq: 100, text: "fresh-nonbarrier-replay"),
    ])
    await router.releaseAllHeld()
    let retryRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterMount + 2
    )
    #expect(retryRequested, "a stale non-barrier replay behind pending input must request a replacement")
    let freshReplayDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("fresh-nonbarrier-replay") }
    }
    #expect(freshReplayDelivered)
    collector.unmount()
}

@MainActor
@Test func renderGridReplayRetryExhaustionClearsBarrierForTargetFrame() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let surfaceID = "live-terminal"
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    let replayBarrierToken = store.beginTerminalReplayBarrier(surfaceID: surfaceID)
    let droppedOutputAccepted = store.deliverTerminalBytes(Data("live-during-barrier".utf8), surfaceID: surfaceID)
    #expect(!droppedOutputAccepted)
    await store.submitTerminalRawInput(Data("x".utf8), surfaceID: surfaceID)
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)

    try await router.enqueueReplayRenderGridFrames([
        renderGridFrame(surfaceID: surfaceID, seq: 97, text: "stale-replay-1"),
        renderGridFrame(surfaceID: surfaceID, seq: 98, text: "stale-replay-2"),
        renderGridFrame(surfaceID: surfaceID, seq: 99, text: "stale-replay-3"),
    ])
    store.requestTerminalReplay(surfaceID: surfaceID, replayBarrierToken: replayBarrierToken)
    let exhaustedRetriesSent = await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCountAfterMount + 3)
    #expect(exhaustedRetriesSent)
    let replaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(replaySettled)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 100,
        text: "target-after-exhaustion",
        columns: 40
    ))
    let targetFrameDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("target-after-exhaustion") }
    }
    #expect(targetFrameDelivered, "retry exhaustion must not leave the replay barrier blocking the target frame")
    collector.unmount()
}

private func renderGridFrame(surfaceID: String, seq: UInt64, text: String) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        // Wide enough for the descriptive marker texts these tests paint;
        // frame validation rejects spans wider than the grid.
        columns: 40,
        rows: 4,
        rowSpans: [
            .init(row: 0, column: 0, text: text),
        ]
    )
}

@MainActor
@Test func renderGridEmptyReplayResponsesConsumeRetryBudgetForDroppedInputCatchUp() async throws {
    let clock = TestClock()
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)

    let surfaceID = "live-terminal"
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    let sawReplay = try await pollUntil { await router.count(of: "mobile.terminal.replay") >= 1 }
    #expect(sawReplay, "mounting a sink must arm the cold-attach replay")
    let mountReplaySettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(mountReplaySettled)
    let replayCountAfterMount = await router.count(of: "mobile.terminal.replay")
    let transport = try #require(box.get())

    await store.submitTerminalRawInput(Data("a".utf8), surfaceID: surfaceID)
    let inputSent = try await pollUntil { await router.count(of: "terminal.input") >= 1 }
    #expect(inputSent)

    // A delta behind the pending target arms the dropped-frame marker.
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 98,
        text: "armed-drop",
        full: false
    ))

    // Each further delta re-arms a replay; the router answers every replay
    // with an empty response (nothing enqueued), which makes no progress.
    // The empty responses must consume the retry budget so the requests
    // stop instead of looping once per delta forever.
    var deltaSeq: UInt64 = 100
    for _ in 0..<5 {
        await transport.deliver(try renderGridEventFrame(
            surfaceID: surfaceID,
            seq: deltaSeq,
            text: "delta-during-empty-replays",
            columns: 40,
            full: false
        ))
        deltaSeq += 1
        _ = try await pollUntil(attempts: 50) {
            !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
        }
    }

    let budgetSpent = try await pollUntil {
        await router.count(of: "mobile.terminal.replay")
            >= replayCountAfterMount + MobileShellComposite.maxTerminalReplayFailureRetries
    }
    #expect(budgetSpent, "dropped deltas must re-arm replays until the retry budget runs out")
    let replayCountAfterExhaustion = await router.count(of: "mobile.terminal.replay")
    #expect(
        replayCountAfterExhaustion <= replayCountAfterMount + MobileShellComposite.maxTerminalReplayFailureRetries,
        "no-progress empty replay responses must consume the bounded retry budget"
    )

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: deltaSeq,
        text: "delta-after-empty-exhaustion",
        columns: 40,
        full: false
    ))
    let replayAfterExhaustion = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: replayCountAfterExhaustion + 1,
        timeoutNanoseconds: 500_000_000,
        recordIssueOnTimeout: false
    )
    #expect(!replayAfterExhaustion, "exhausted retry budget must stop live-event replay requests")
    collector.unmount()
}
