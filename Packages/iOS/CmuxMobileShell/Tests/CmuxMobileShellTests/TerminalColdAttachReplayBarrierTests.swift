import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func coldAttachReplayFailureExhaustionReleasesLiveOutputBarrier() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.failNextReplay(count: 3)
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    let retriesExhausted = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(retriesExhausted, "cold attach should try the initial replay plus two retries")

    let failureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    let accepted = store.deliverTerminalBytes(
        Data("live-after-cold-replay-failure".utf8),
        surfaceID: surfaceID
    )
    #expect(accepted)

    let chunk = try #require(await iterator.next())
    #expect(String(data: chunk.data, encoding: .utf8) == "live-after-cold-replay-failure")
}

@MainActor
@Test func coldAttachReplayFailureWaitsForFullRenderGridBaseline() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.failNextReplay(count: 3)
    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)

    let retriesExhausted = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(retriesExhausted, "cold attach should try the initial replay plus two retries")

    let failureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-after-failed-replay",
        full: false
    ))
    let replayCountAfterFailure = await router.count(of: "mobile.terminal.replay")
    #expect(!collector.lines.contains { $0.contains("partial-after-failed-replay") }, "partial render-grid deltas must wait for a baseline after failed cold replay")
    #expect(
        await router.count(of: "mobile.terminal.replay") == replayCountAfterFailure,
        "partial render-grid deltas must not retry replay on every event after retries are exhausted"
    )

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "full-after-failed-replay",
        full: true
    ))
    let fullDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("full-after-failed-replay") }
    }
    #expect(fullDelivered, "a full live render-grid frame can establish the post-failure baseline")

    collector.unmount()
}

@MainActor
@Test func coldAttachFollowUpReplayFailureExhaustionReleasesLiveOutputBarrier() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let coldReplayChunk = try #require(await iterator.next())
    let droppedDuringColdReplay = store.deliverTerminalBytes(
        Data("live-during-cold-replay".utf8),
        surfaceID: surfaceID
    )
    #expect(!droppedDuringColdReplay)

    await router.failNextReplay(count: 3)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)

    let followUpRetriesExhausted = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 4,
        recordIssueOnTimeout: false
    )
    #expect(followUpRetriesExhausted, "cold follow-up replay should try the initial follow-up plus two retries")

    let failureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    let accepted = store.deliverTerminalBytes(
        Data("live-after-follow-up-failure".utf8),
        surfaceID: surfaceID
    )
    #expect(accepted)

    let chunk = try #require(await iterator.next())
    #expect(String(data: chunk.data, encoding: .utf8) == "live-after-follow-up-failure")
}

@MainActor
@Test func partialRenderGridDuringColdAttachDoesNotConsumeReplayRetries() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.holdNextReplayResponses()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-during-cold-replay",
        full: false
    ))
    #expect(!collector.lines.contains { $0.contains("partial-during-cold-replay") })

    await router.failNextReplay(count: 3)
    await router.releaseAllHeld()

    let retriesExhausted = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(retriesExhausted, "partial live grids must not consume the cold replay retry budget")

    collector.unmount()
}

@MainActor
@Test func fullRenderGridDuringColdAttachEstablishesBaseline() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.holdNextReplayResponses()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 7,
        text: "full-during-cold-replay",
        full: true
    ))
    let fullDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("full-during-cold-replay") }
    }
    #expect(fullDelivered, "a full live render-grid frame should establish the cold-attach baseline")

    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(barrierCleared)

    collector.unmount()
    await router.releaseAllHeld()
}

@MainActor
@Test func missingBaselinePartialRenderGridCanRetryAfterTransientReplayFailure() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await router.failNextReplay()
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-before-transient-failure",
        full: false
    ))
    let firstBaselineReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 2,
        recordIssueOnTimeout: false
    )
    #expect(firstBaselineReplayRequested)

    let transientFailureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(transientFailureSettled)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "partial-after-transient-failure",
        full: false
    ))
    let secondBaselineReplayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(secondBaselineReplayRequested, "transient baseline replay failure must not permanently suppress recovery")

    collector.unmount()
}

@MainActor
@Test func missingBaselineReplayRequestsFollowUpForPartialDuringRecovery() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)

    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    await router.holdNextReplayResponses()
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-starts-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "partial-during-baseline-replay",
        full: false
    ))
    await router.enqueueReplayTexts(["baseline-replay", "follow-up-replay"])
    await router.releaseAllHeld()

    let baselineDelivered = try await pollUntil {
        collector.lines.contains("baseline-replay")
    }
    #expect(baselineDelivered)
    let followUpRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 3,
        recordIssueOnTimeout: false
    )
    #expect(followUpRequested, "partials dropped during baseline replay must request a follow-up replay")
    let followUpDelivered = try await pollUntil {
        collector.lines.contains("follow-up-replay")
    }
    #expect(followUpDelivered)

    collector.unmount()
}

@MainActor
@Test func fullRenderGridDuringMissingBaselineRecoveryEstablishesBaseline() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    await router.holdNextReplayResponses()
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-starts-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)

    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "partial-during-baseline-replay",
        full: false
    ))
    let replayCountBeforeFull = await router.count(of: "mobile.terminal.replay")
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 6,
        text: "full-during-baseline-replay",
        full: true
    ))
    let fullDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("full-during-baseline-replay") }
    }
    #expect(fullDelivered, "full live frames must satisfy a missing-baseline recovery barrier")
    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(barrierCleared)
    #expect(
        await router.count(of: "mobile.terminal.replay") == replayCountBeforeFull,
        "full live frame should cover earlier drops in the same recovery barrier"
    )

    collector.unmount()
    await router.releaseAllHeld()
}

@MainActor
@Test func partialAlternateRenderGridWaitingForBaselineSuppressesRawBytes() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    let collector = OutputCollector()
    collector.mount(store: store, surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-alt-waiting-baseline",
        activeScreen: .alternate,
        full: false
    ))
    await transport.deliver(try terminalBytesEventFrame(
        surfaceID: surfaceID,
        seq: 0,
        text: "raw-after-alt-partial"
    ))
    let rawDelivered = try await pollUntil(attempts: 50) {
        collector.lines.contains { $0.contains("raw-after-alt-partial") }
    }
    #expect(!rawDelivered, "partial alternate-screen frames waiting for baseline must still suppress raw bytes")

    collector.unmount()
}

@MainActor
@Test func missingBaselineFollowUpReplayFailureReleasesBarrier() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplaySettledEmpty = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
            && store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
            && store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == nil
    }
    #expect(coldReplaySettledEmpty)

    await router.holdNextReplayResponses()
    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 4,
        text: "partial-starts-baseline-replay",
        full: false
    ))
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 5,
        text: "partial-during-baseline-replay",
        full: false
    ))

    await router.enqueueReplayTexts(["baseline-replay"])
    await router.releaseAllHeld()
    let baselineChunk = try #require(await iterator.next())

    await router.failNextReplay(count: 3)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: baselineChunk.streamToken)
    let followUpRetriesExhausted = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 5,
        recordIssueOnTimeout: false
    )
    #expect(followUpRetriesExhausted)

    let failureSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(failureSettled)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    let accepted = store.deliverTerminalBytes(
        Data("live-after-missing-baseline-follow-up-failure".utf8),
        surfaceID: surfaceID
    )
    #expect(accepted)
    let chunk = try #require(await iterator.next())
    #expect(String(data: chunk.data, encoding: .utf8) == "live-after-missing-baseline-follow-up-failure")
}
