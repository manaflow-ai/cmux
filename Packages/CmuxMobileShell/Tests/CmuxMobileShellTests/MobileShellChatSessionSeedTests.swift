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
}
