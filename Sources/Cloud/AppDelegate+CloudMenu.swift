import AppKit
import CmuxCloud
import Foundation

/// Binds the shared Cloud menu (status item and main-menu Cloud menu) to the
/// app's existing Cloud entrypoints. No verb here has its own implementation:
/// each one calls the action the File menu, palette, sidebar or CLI already use.
extension AppDelegate {
    /// What a Cloud menu should show right now.
    @MainActor
    func cloudMenuContext(model: CloudMenuModel? = nil) -> CloudMenuContext {
        let model = model ?? .shared
        guard CloudMachinesFeature.isEnabled, let flow = auth?.accountFlow else {
            return CloudMenuContext(account: .unavailable)
        }
        guard flow.isAuthenticated else {
            return CloudMenuContext(account: .signedOut(isSigningIn: flow.isWorkingOnAuth))
        }
        let identity = flow.currentIdentity
        let account = CloudMenuAccount(
            email: identity.flatMap { $0.email.isEmpty ? nil : $0.email },
            displayName: identity.flatMap { $0.displayName.isEmpty ? nil : $0.displayName },
            teams: flow.availableTeams,
            selectedTeamID: flow.selectedTeamID,
            isSelectingTeam: flow.isSelectingTeam
        )
        return CloudMenuContext(account: .signedIn(account), machines: model.machines, loadState: model.loadState)
    }

    /// The Cloud verbs. `fromStatusItem` brings cmux forward first, because a
    /// status item click leaves the app inactive and Cloud creation only
    /// navigates a window that is key when it finishes.
    @MainActor
    func cloudMenuActions(model: CloudMenuModel? = nil, fromStatusItem: Bool) -> CloudMenuActions {
        let model = model ?? .shared
        let source = fromStatusItem ? "menuBarExtra.cloud" : "mainMenu.cloud"
        let window: @MainActor () -> NSWindow? = { [weak self] in
            if fromStatusItem { return self?.showMainWindowFromMenuBar() }
            return NSApp.keyWindow ?? NSApp.mainWindow
        }
        let rowActions = MachineRowActions.bound(onDidMutate: { [weak model] in model?.refresh() })
        let machine = CloudMachineMenuVerbs(
            openShell: { id in _ = window(); rowActions.openShell(id) },
            newWorkspace: { [weak self] id in
                let preferred = window()
                guard let self, let manager = self.activeTabManagerForCommands(preferredWindow: preferred),
                      self.performNewCloudWorkspaceOnCurrentMachineAction(tabManager: manager, vmID: id) else {
                    NSSound.beep()
                    return
                }
            },
            openDesktop: { id in _ = window(); rowActions.openDesktop(id) },
            runCommand: { id, verb in _ = window(); rowActions.runCommand(id, verb) },
            promptRename: { machine in _ = window(); rowActions.promptRename(machine) },
            copyToPasteboard: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            confirmDelete: { machine in _ = window(); rowActions.confirmDelete(machine) },
            promptUpgrade: { _ = window(); rowActions.promptUpgrade() }
        )
        return CloudMenuActions(
            signIn: { [weak self] in
                if fromStatusItem { NSApp.activate() }
                self?.auth?.accountFlow.startSignIn()
            },
            signOut: { [weak self] in
                guard let flow = self?.auth?.accountFlow else { return }
                Task { @MainActor in await flow.signOut() }
            },
            selectTeam: { [weak self] teamID in
                guard let flow = self?.auth?.accountFlow, teamID != flow.selectedTeamID, !flow.isSelectingTeam else { return }
                Task { @MainActor in
                    do { try await flow.selectTeam(id: teamID) } catch { NSSound.beep() }
                }
            },
            newWorkspace: { [weak self] in
                let preferred = window()
                if self?.performNewCloudWorkspaceOnResolvedMachineAction(preferredWindow: preferred, debugSource: source) != true {
                    NSSound.beep()
                }
            },
            newMachine: { [weak self] in
                let preferred = window()
                _ = self?.performNewCloudMachineAction(preferredWindow: preferred, debugSource: source)
            },
            showMachines: { [weak self] in
                let preferred = window()
                if self?.revealCloudMachinesSidebar(preferredWindow: preferred) != true { NSSound.beep() }
            },
            openDashboard: {
                _ = NSWorkspace.shared.open(AuthEnvironment.apiBaseURL.appendingPathComponent("dashboard/cloud"))
            },
            showDiagnostics: { [weak self] in
                if fromStatusItem { NSApp.activate() }
                self?.showCloudDiagnostics()
            },
            upgrade: { [weak self] in self?.auth?.accountFlow.openProUpgrade() },
            retry: { [weak model] in model?.refresh() },
            machine: machine
        )
    }

    /// Opens the right sidebar on its Cloud machines tab, the same reveal the
    /// team picker uses.
    @MainActor
    @discardableResult
    func revealCloudMachinesSidebar(preferredWindow: NSWindow?) -> Bool {
        guard RightSidebarMode.machines.isAvailable(),
              let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let state = context.fileExplorerState else { return false }
        state.mode = .machines
        state.setVisible(true)
        _ = focusRightSidebarInActiveMainWindow(
            mode: .machines,
            focusFirstItem: false,
            preferredWindow: context.window ?? preferredWindow
        )
        return true
    }
}
