import CmuxMobilePairedMac
import CmuxMobileSSH
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation
import Testing
@testable import CmuxMobileShellUI

@Suite("SSH computers UI policy")
struct SSHComputersUITests {
    // MARK: Host form validation

    @Test func draftRequiresHostUsernameAndValidPort() {
        var draft = SSHComputerDraft()
        #expect(draft.validationMessage != nil)
        draft.host = "  server.example.com "
        draft.username = "aziz"
        #expect(draft.validationMessage == nil)
        draft.port = "0"
        #expect(draft.validationMessage != nil)
        draft.port = "65536"
        #expect(draft.validationMessage != nil)
        draft.port = "2222"
        #expect(draft.validationMessage == nil)
        draft.username = " "
        #expect(draft.validationMessage != nil)
    }

    @Test func draftRecordTrimsFieldsDefaultsNameAndUnbracketsIPv6() throws {
        var draft = SSHComputerDraft()
        draft.host = "[fe80::1]"
        draft.username = "root"
        let id = UUID()
        draft.jumpHostID = id
        let record = try #require(draft.record(id: id, existing: nil))
        #expect(record.endpoint.host == "fe80::1")
        #expect(record.endpoint.port == 22)
        #expect(record.name == "fe80::1")
        // A host can never jump through itself.
        #expect(record.jumpHostID == nil)
        #expect(record.idleClose == .oneDay)
    }

    @Test func endpointDisplayAddressBracketsIPv6WithCustomPort() {
        #expect(SSHEndpoint(host: "box", username: "me").sshDisplayAddress == "me@box")
        #expect(SSHEndpoint(host: "fe80::1", port: 2222, username: "me").sshDisplayAddress == "me@[fe80::1]:2222")
    }

    // MARK: Root presentation

    @Test func pairingSwapsToSSHFormAndFinishesPairing() {
        var state = MobileRootPresentationState()
        state.apply(.presentPairing(.manual))
        let effect = state.apply(.presentSSHComputerEditor(.new))
        #expect(state.presentation == .sshComputerEditor(.new))
        #expect(effect == .finishPairing)
        #expect(state.isRootSheetPresented)
        #expect(state.apply(.dismissSSHComputerEditor) == .retryAutoConnectMigration)
        #expect(state.isIdle)
    }

    @Test func sshFormDoesNotStealChildSheets() {
        var state = MobileRootPresentationState()
        state.apply(.presentChild(.workspaceTaskComposer))
        state.apply(.presentSSHComputerEditor(.new))
        #expect(state.presentation == .child(.workspaceTaskComposer))
    }

    @Test func swipeDismissClosesSSHForm() {
        var state = MobileRootPresentationState()
        state.apply(.presentSSHComputerEditor(.edit(UUID())))
        #expect(state.apply(.sheetDidRequestDismissal) == .none)
        #expect(state.isIdle)
    }

    // MARK: Shell presentation

    @Test func sshComputersKeepTheWorkspaceShell() {
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false,
            hasSSHComputers: true
        ) == .workspace)
        #expect(MobileAuthenticatedShellPresentation.resolve(
            connectionState: .disconnected,
            hasKnownPairedMac: false,
            hasHiddenComputers: false
        ) == .disconnected)
    }

    // MARK: Computer selection

    @Test func sshComputerIsSelectableAndCreatableWithoutWorkspacesOrMac() {
        let sshID = "cmux-ssh-00000000-0000-0000-0000-000000000001"
        let scope = WorkspaceMacSelectionScope(
            selection: .machine(sshID),
            workspaces: [],
            displayPairedMacs: [],
            foregroundMacDeviceID: nil,
            locallyServedMachineIDs: [sshID],
            aliasesFor: { _ in [] }
        )
        #expect(scope.visibleSelection == .machine(sshID))
        #expect(scope.canCreateWorkspace(base: false))
        #expect(scope.shouldSwitch(to: sshID))
        #expect(scope.switchTarget(for: sshID)?.macDeviceID == sshID)
        #expect(!scope.canMutateForegroundGroupsForSelection)
    }

    // MARK: Signed-out preference

    @MainActor
    @Test func signedOutPreferenceIsAutomaticUntilChosen() throws {
        let defaults = try #require(UserDefaults(suiteName: "SSHComputersUITests.\(UUID().uuidString)"))
        let preference = MobileSSHOnlyPreference(defaults: defaults)
        #expect(!preference.showsSignedOutShell(hasSSHComputers: false))
        #expect(preference.showsSignedOutShell(hasSSHComputers: true))
        preference.chooseSSHShell()
        #expect(preference.showsSignedOutShell(hasSSHComputers: false))
        #expect(MobileSSHOnlyPreference(defaults: defaults).choice == true)
        preference.chooseSignIn()
        #expect(!preference.showsSignedOutShell(hasSSHComputers: true))
        preference.reset()
        #expect(MobileSSHOnlyPreference(defaults: defaults).choice == nil)
    }
}
