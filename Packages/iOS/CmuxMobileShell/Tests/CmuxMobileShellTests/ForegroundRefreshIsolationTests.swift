import Testing
@testable import CmuxMobileShell

@MainActor
struct ForegroundRefreshIsolationTests {
    @Test func foregroundRefreshDoesNotWaitForSecondaryDiscovery() async throws {
        let paired = DelayedTeamPairedMacStore(recordsByTeam: [:], blockedTeams: [""])
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter(), pairedMacStore: paired)
        var completed = false
        let pull = Task { @MainActor in
            await store.refreshWorkspaces()
            completed = true
        }
        await paired.waitUntilLoadStarted(teamID: nil)
        for _ in 0..<100 where !completed { await Task.yield() }
        let completedWhileSecondaryWasBlocked = completed
        await paired.release(teamID: nil)
        await pull.value
        #expect(completedWhileSecondaryWasBlocked)
        #expect(store.connectionState == .connected)
        #expect(!store.workspaces.isEmpty)
        store.pauseForegroundRefresh()
    }
}
