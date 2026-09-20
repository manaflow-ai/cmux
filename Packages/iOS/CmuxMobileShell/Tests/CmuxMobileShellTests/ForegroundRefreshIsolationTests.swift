import Testing
@testable import CmuxMobileShell

@MainActor
struct ForegroundRefreshIsolationTests {
    @Test func foregroundRefreshDoesNotWaitForSecondaryDiscovery() async throws {
        let paired = DelayedTeamPairedMacStore(recordsByTeam: [:], blockedTeams: [""])
        let store = try await makeRoutingConnectedStore(router: RoutingHostRouter(), pairedMacStore: paired)
        let completedWhileSecondaryWasBlocked = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await store.refreshWorkspaces()
                return true
            }
            // A failure deadline, not the readiness signal. Success comes only
            // from refresh returning while the secondary dependency is blocked.
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            await paired.waitUntilLoadStarted(teamID: nil)
            let completed = await group.next() ?? false
            await paired.release(teamID: nil)
            group.cancelAll()
            return completed
        }
        #expect(completedWhileSecondaryWasBlocked)
        #expect(store.connectionState == .connected)
        #expect(!store.workspaces.isEmpty)
        store.suspendForegroundRefresh()
    }
}
