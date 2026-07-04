import CmuxMobileShellModel
import Testing
@testable import CmuxMobileShell

@MainActor
@Suite struct CreatedTerminalSelectionTests {
    @Test func createdTerminalSelectionSurvivesNotReadyWorkspaceRefresh() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()

        store.createTerminal()
        let created = try #require(store.selectedTerminalID)

        store.replaceForegroundWorkspaceState([
            MobileWorkspacePreview(
                id: "workspace-main",
                name: "cmux",
                terminals: [
                    MobileTerminalPreview(
                        id: "terminal-build",
                        name: "Build",
                        isReady: true,
                        isFocused: true
                    ),
                    MobileTerminalPreview(
                        id: created,
                        name: "Terminal 4",
                        isReady: false,
                        isFocused: false
                    ),
                ]
            ),
        ])
        store.selectedWorkspaceID = "workspace-main"

        #expect(store.selectedTerminalID == created)
    }

    @Test func remoteCreatedTerminalSelectionSurvivesNotReadyWorkspaceRefresh() async throws {
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
