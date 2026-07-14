import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Test func staleWorkspaceFailureDoesNotRecoverReplacementClient() async throws {
    let clock = TestClock()
    let staleRouter = LivenessHostRouter()
    let staleBox = TransportBox()
    await staleRouter.setCapabilities([
        "events.v1",
        "terminal.render_grid.v1",
        "terminal.replay.v1",
        "workspace.actions.v1",
    ])
    let store = try await makeConnectedStore(
        router: staleRouter,
        box: staleBox,
        clock: clock
    )
    let workspaceID = try #require(store.workspaces.first?.id)
    await staleRouter.holdNextWorkspaceAction()

    let mutation = Task { @MainActor in
        await store.renameWorkspace(id: workspaceID, title: "Renamed")
    }
    #expect(await staleRouter.waitForCount(of: "workspace.action", atLeast: 1))

    let replacementRouter = LivenessHostRouter()
    let replacementBox = TransportBox()
    try installFreshLivenessRemoteClient(
        on: store,
        router: replacementRouter,
        box: replacementBox,
        clock: clock
    )
    store.connectionGeneration = UUID()
    await staleRouter.releaseAllHeld()
    _ = await mutation.value

    #expect(await replacementRouter.count(of: "mobile.host.status") == 0)
    #expect(store.macConnectionStatus != .reconnecting)
}
