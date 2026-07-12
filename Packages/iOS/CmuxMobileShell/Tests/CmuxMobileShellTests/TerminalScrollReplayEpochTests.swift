import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

@MainActor
@Test func delayedReplayFromPriorScrollEpochRequestsFreshReplay() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    await router.enqueueReplayTexts(["cold-replay", "stale-replay", "fresh-replay"])

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    let coldSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldSettled)

    let token = store.mountTerminalScrollSession(
        surfaceID: surfaceID,
        cancelLocal: {}
    )
    let oldEpoch = try #require(store.currentTerminalInteractionEpoch(surfaceID: surfaceID))
    let replayCount = await router.count(of: "mobile.terminal.replay")
    await router.holdNextReplayResponses()
    store.requestTerminalReplay(surfaceID: surfaceID, interactionEpoch: oldEpoch)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCount + 1)

    let firstInputEpoch = try #require(store.invalidateTerminalScrollForInput(surfaceID: surfaceID))
    let secondInputEpoch = try #require(store.invalidateTerminalScrollForInput(surfaceID: surfaceID))
    #expect(firstInputEpoch != oldEpoch)
    #expect(secondInputEpoch != firstInputEpoch)
    await router.releaseAllHeld()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCount + 2)

    let bottom = try #require(await iterator.next())
    #expect(bottom.mutation == .scrollToBottom)
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: bottom.streamToken)

    let fresh = try #require(await iterator.next())
    #expect(String(data: fresh.data, encoding: .utf8) == "fresh-replay")
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: fresh.streamToken)
    store.unmountTerminalScrollSession(surfaceID: surfaceID, token: token)
}

@MainActor
@Test func replayCannotLowerAcceptedRenderRevision() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    var coldFrame = try renderGridFrame(surfaceID: surfaceID, seq: 10, text: "cold-grid")
    coldFrame.renderRevision = 20
    var staleFrame = try renderGridFrame(surfaceID: surfaceID, seq: 11, text: "stale-grid")
    staleFrame.renderRevision = 19
    var freshFrame = try renderGridFrame(surfaceID: surfaceID, seq: 12, text: "fresh-grid")
    freshFrame.renderRevision = 21
    await router.enqueueReplayRenderGridFrames([coldFrame, staleFrame, freshFrame])

    var iterator = store.terminalOutputStream(surfaceID: surfaceID).makeAsyncIterator()
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: 1)
    let cold = try #require(await iterator.next())
    #expect(String(decoding: cold.data, as: UTF8.self).contains("cold-grid"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: cold.streamToken)
    let coldSettled = try await pollUntil {
        !store.terminalReplaySurfaceIDsInFlight.contains(surfaceID)
    }
    #expect(coldSettled)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 20)

    let replayCount = await router.count(of: "mobile.terminal.replay")
    store.requestTerminalReplay(surfaceID: surfaceID)
    await router.waitForCount(of: "mobile.terminal.replay", atLeast: replayCount + 2)

    let fresh = try #require(await iterator.next())
    #expect(String(decoding: fresh.data, as: UTF8.self).contains("fresh-grid"))
    #expect(!String(decoding: fresh.data, as: UTF8.self).contains("stale-grid"))
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: fresh.streamToken)
    #expect(store.acceptedTerminalRenderRevisionsBySurfaceID[surfaceID] == 21)
}
