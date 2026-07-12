import Testing

@testable import CmuxMobileShell

@MainActor
@Test("Authoritative replay requests a large bidirectional history window")
func authoritativeReplayRequestsLargeBidirectionalHistory() async throws {
    let router = LivenessHostRouter()
    let box = TransportBox()
    let clock = TestClock()
    let store = try await makeConnectedStore(router: router, box: box, clock: clock)
    let surfaceID = "live-terminal"
    await router.enqueueReplayTexts(["cold-replay"])

    let mount = store.mountTerminalSurfaceOutput(
        surfaceID: surfaceID,
        cancelLocal: {}
    )
    var iterator = mount.output.makeAsyncIterator()
    let replayRequested = await router.waitForCount(
        of: "mobile.terminal.replay",
        atLeast: 1
    )
    #expect(replayRequested)

    let prefetch = try #require(await router.replayPrefetches().last)
    #expect(prefetch == LivenessHostRouter.ReplayPrefetch(
        beforeRows: 600,
        afterRows: 120,
        legacyRows: 600
    ))

    let chunk = try #require(await iterator.next())
    store.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
    store.unmountTerminalScrollSession(surfaceID: surfaceID, token: mount.scrollSessionToken)
}
