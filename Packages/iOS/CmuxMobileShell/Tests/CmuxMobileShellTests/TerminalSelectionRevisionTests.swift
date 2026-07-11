import Testing
@testable import CmuxMobileShell

@MainActor
@Suite("Terminal selection revision")
struct TerminalSelectionRevisionTests {
    @Test func advancesOnlyForExplicitSelectionIntent() throws {
        let store = MobileShellComposite.preview()
        store.signIn()
        store.pairingCode = "debug"
        store.connectPreviewHost()
        let initialRevision = store.userTerminalSelectionRevision
        let currentTerminalID = try #require(store.selectedTerminalID)
        let terminalID = try #require(store.selectedWorkspace?.terminals.first { $0.id != currentTerminalID }?.id)

        store.selectTerminalFromChrome(terminalID)
        #expect(store.userTerminalSelectionRevision == initialRevision + 1)

        store.selectedWorkspaceID = "workspace-docs"
        #expect(store.userTerminalSelectionRevision == initialRevision + 1)
    }
}
