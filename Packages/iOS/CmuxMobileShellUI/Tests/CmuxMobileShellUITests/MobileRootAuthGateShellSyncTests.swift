import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileWorkspace
import Foundation
import Testing
@testable import CmuxMobileShellUI

@MainActor
@Suite struct MobileRootAuthGateShellSyncTests {
    @Test func authenticatedUserReplacementClearsPreviousAccountsShellState() {
        let identity = WorkspaceMacSelectionIdentityProvider(userID: "user-a")
        let privateWorkspace = MobileWorkspacePreview(
            id: "user-a-private-workspace",
            name: "User A Private Workspace",
            terminals: [
                MobileTerminalPreview(
                    id: "user-a-private-terminal",
                    name: "Private Terminal"
                ),
            ]
        )
        let defaults = UserDefaults(
            suiteName: "MobileRootAuthGateShellSyncTests-\(UUID().uuidString)"
        )!
        let store = MobileShellComposite(
            workspaces: [privateWorkspace],
            clientIDRepository: MobileClientIDRepository(defaults: defaults),
            identityProvider: identity,
            pairingHintDefaults: defaults,
            multiMacAggregationDefaults: defaults
        )
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: true,
            store: store
        )
        store.terminalInputText = "user-a-unsent-secret"

        identity.currentUserID = "user-b"
        MobileRootAuthGate.syncShellAuthentication(
            stackAuthenticated: true,
            store: store
        )

        #expect(store.terminalInputText.isEmpty)
        #expect(!store.workspaces.contains(where: { $0.id == privateWorkspace.id }))
        #expect(store.selectedWorkspaceID != privateWorkspace.id)
        #expect(store.selectedTerminalID != privateWorkspace.terminals.first?.id)
    }
}
