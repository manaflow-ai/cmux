import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func sustainedTerminalOutputOverloadReplacesBacklogWithAuthoritativeReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"

    await router.enqueueReplayTexts(["cold-replay", "overload-replay"])
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let coldReplayChunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: coldReplayChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())

    for index in 0..<32 {
        let admitted = store.deliverTerminalBytes(
            Data("queued-\(index)".utf8),
            surfaceID: surfaceID
        )
        #expect(admitted)
    }
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount == 32)

    let overloadAdmitted = store.deliverTerminalBytes(
        Data("queue-overload".utf8),
        surfaceID: surfaceID
    )
    try #require(!overloadAdmitted)
    let replayStreamToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    #expect(replayStreamToken != stalledChunk.streamToken)
    #expect((store.terminalOutputQueuesBySurfaceID[surfaceID]?.pendingCount ?? 0) <= 1)

    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 2)
    let overloadReplayChunk = try #require(await iterator.next())
    #expect(String(data: overloadReplayChunk.data, encoding: .utf8) == "overload-replay")
    #expect(overloadReplayChunk.streamToken == replayStreamToken)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: stalledChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] != nil)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: overloadReplayChunk.streamToken
    )
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.deliverTerminalBytes(Data("live-after-recovery".utf8), surfaceID: surfaceID)
    let recoveredChunk = try #require(await iterator.next())
    #expect(String(data: recoveredChunk.data, encoding: .utf8) == "live-after-recovery")
}

@MainActor
@Test func terminalOutputOverloadInvalidatesStaleAckWithoutRemoteClient() async throws {
    let store = MobileShellComposite.preview()
    let surfaceID = "terminal"
    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()

    store.deliverTerminalBytes(Data("stalled-apply".utf8), surfaceID: surfaceID)
    let stalledChunk = try #require(await iterator.next())
    for index in 0..<TerminalOutputDeliveryQueue.maximumPendingCount {
        #expect(store.deliverTerminalBytes(Data("queued-\(index)".utf8), surfaceID: surfaceID))
    }

    let overloadAdmitted = store.deliverTerminalBytes(
        Data("queue-overload".utf8),
        surfaceID: surfaceID
    )
    try #require(!overloadAdmitted)
    let replacementToken = try #require(store.terminalOutputStreamTokensBySurfaceID[surfaceID])
    try #require(replacementToken != stalledChunk.streamToken)
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)
    #expect(store.terminalReplayBarrierTokensBySurfaceID[surfaceID] == nil)

    store.terminalOutputDidProcess(
        surfaceID: surfaceID,
        streamToken: stalledChunk.streamToken
    )
    #expect(store.terminalOutputQueuesBySurfaceID[surfaceID]?.isIdle == true)

    #expect(store.deliverTerminalBytes(Data("live-after-recovery".utf8), surfaceID: surfaceID))
    let recoveredChunk = try #require(await iterator.next())
    #expect(recoveredChunk.streamToken == replacementToken)
    #expect(String(data: recoveredChunk.data, encoding: .utf8) == "live-after-recovery")
}
