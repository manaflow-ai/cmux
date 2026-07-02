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

    await store.submitTerminalRawInput(Data("b".utf8), surfaceID: "live-terminal")
    let secondInputSent = try await pollUntil { await router.count(of: "terminal.input") >= 2 }
    #expect(secondInputSent)
    let replayRequested = try await pollUntil {
        await router.count(of: "mobile.terminal.replay") > replayCountAfterMount
    }
    #expect(replayRequested, "a pending input target that survived a dropped frame and another ACK must request replay")
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

    try await router.enqueueReplayRenderGrids([
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

private func renderGridFrame(surfaceID: String, seq: UInt64, text: String) throws -> MobileTerminalRenderGridFrame {
    try MobileTerminalRenderGridFrame(
        surfaceID: surfaceID,
        stateSeq: seq,
        columns: 16,
        rows: 4,
        rowSpans: [
            .init(row: 0, column: 0, text: text),
        ]
    )
}
