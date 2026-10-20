import CMUXMobileCore
import CmuxMobileRPC
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func completeViewportPatchDuringColdAttachEstablishesBaseline() async throws {
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
    let frame = try MobileTerminalRenderGridFrame.fromPlainRows(
        surfaceID: surfaceID,
        stateSeq: 20,
        columns: 16,
        rows: 4,
        text: "viewport\npatch\nbaseline\nready",
        full: false,
        changedRows: [0, 1, 2, 3]
    )
    #expect(frame.isReplaceableViewportPatchForMobileDelivery)
    let envelope: [String: Any] = [
        "kind": "event",
        "topic": "terminal.render_grid",
        "payload": try frame.jsonObject(),
    ]
    let eventData = try JSONSerialization.data(withJSONObject: envelope)
    await transport.deliver(try MobileSyncFrameCodec.encodeFrame(eventData))

    let patchDelivered = try await pollUntil {
        collector.lines.contains { $0.contains("baseline") }
    }
    #expect(patchDelivered, "complete viewport patches must satisfy a cold-attach replay barrier")
    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(barrierCleared)

    collector.unmount()
    await router.releaseAllHeld()
}

@MainActor
@Test func fullRenderGridAfterReplayBarrierClearsDoesNotResetOutputQueue() async throws {
    let router = LivenessHostRouter()
    await router.setCapabilities(["events.v1", "terminal.render_grid.v1", "terminal.replay.v1"])
    await router.enqueueReplayTexts(["cold-replay"])
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    #expect(String(data: coldReplayChunk.data, encoding: .utf8) == "cold-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: coldReplayChunk.streamToken)
    let barrierCleared = try await pollUntil {
        store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil
    }
    #expect(barrierCleared)

    let firstRawAccepted = store.deliverTerminalBytes(
        Data("raw-in-flight".utf8),
        surfaceID: surfaceID
    )
    #expect(firstRawAccepted)
    let rawInFlightChunk = try #require(await iterator.next())
    #expect(String(data: rawInFlightChunk.data, encoding: .utf8) == "raw-in-flight")
    let queuedRawAccepted = store.deliverTerminalBytes(
        Data("raw-queued-after-full".utf8),
        surfaceID: surfaceID
    )
    #expect(queuedRawAccepted)

    let transport = try #require(box.get())
    await transport.deliver(try renderGridEventFrame(
        surfaceID: surfaceID,
        seq: 20,
        text: "normal-full-grid",
        full: true
    ))
    let fullEventProcessed = try await pollUntil {
        store.deliveredTerminalByteEndSeqBySurfaceID[surfaceID] == 20
    }
    #expect(fullEventProcessed)

    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: rawInFlightChunk.streamToken)
    let queuedRawChunk = try #require(await iterator.next())
    #expect(String(data: queuedRawChunk.data, encoding: .utf8) == "raw-queued-after-full")
}
