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
}
