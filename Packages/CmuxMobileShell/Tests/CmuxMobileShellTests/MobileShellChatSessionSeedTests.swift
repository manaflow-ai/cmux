import Foundation
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct MobileShellChatSessionSeedTests {
    @Test func workspaceListSeedsAndClearsFirstPaintChatSessions() async throws {
        let router = LivenessHostRouter()
        await router.setIncludesWorkspaceListChatSession(true)
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )

        let seeded = store.seededChatSessions(workspaceID: "live-workspace")
        #expect(seeded.map(\.id) == ["seeded-session"])
        #expect(seeded.first?.terminalID == "live-terminal")

        await router.setIncludesWorkspaceListChatSession(false)
        await store.refreshWorkspaces()

        #expect(store.seededChatSessions(workspaceID: "live-workspace").isEmpty)
    }

    @Test func workspaceListSeedKeepsOneSessionPerTerminal() async throws {
        let router = LivenessHostRouter()
        await router.setIncludesWorkspaceListChatSession(true)
        await router.setIncludesEndedWorkspaceListChatSession(true)
        let store = try await makeConnectedStore(
            router: router,
            box: TransportBox(),
            clock: TestClock()
        )

        let seeded = store.seededChatSessions(workspaceID: "live-workspace")
        #expect(Set(seeded.map(\.id)) == ["seeded-session", "ended-session"])
        #expect(Set(seeded.compactMap(\.terminalID)) == ["live-terminal", "ended-terminal"])
        #expect(seeded.first { $0.id == "ended-session" }?.state == .ended)
    }
}
