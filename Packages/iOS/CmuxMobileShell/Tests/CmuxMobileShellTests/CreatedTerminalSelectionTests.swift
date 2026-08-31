import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct CreatedTerminalSelectionTests {
    @Test func remoteCreatedTerminalRemainsSelectedAfterRefresh() async throws {
        let router = RoutingHostRouter()
        let store = try await makeRoutingConnectedStore(router: router)
        let created = MobileTerminalPreview.ID(rawValue: RoutingHostRouter.createdTerminal)

        store.createTerminal(in: MobileWorkspacePreview.ID(rawValue: RoutingHostRouter.workspaceID))
        await router.awaitTerminalCreateRequested()
        await waitUntilSelectedTerminal(store, is: created)
        #expect(store.selectedTerminalID == created)

        await store.refreshWorkspaces()

        #expect(store.selectedTerminalID == created)
    }

    private func waitUntilSelectedTerminal(
        _ store: MobileShellComposite,
        is terminalID: MobileTerminalPreview.ID
    ) async {
        for _ in 0..<50 where store.selectedTerminalID != terminalID {
            await Task.yield()
        }
    }
}
