import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellTeamSwitchAuthorizationTests {
    @Test func teamSwitchKeepsForegroundAuthorizationUsable() async throws {
        let router = LivenessHostRouter()
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )
        let requestsBeforeSwitch = await router.count(of: "mobile.workspace.list")

        store.currentTeamDidChange()
        await store.refreshWorkspaces()

        #expect(store.connectionState == .connected)
        #expect(await router.count(of: "mobile.workspace.list") == requestsBeforeSwitch + 1)
    }
}
