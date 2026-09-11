import AppKit
import CmuxSettings
import Foundation

/// Runtime enforcement for MDM managed policies (`DisableEmbeddedBrowser`,
/// `DisableRemoteControl`, `DisableCloud`, and `DisableRemoteConnections`):
/// installs the transition observer and tears down live resources when a
/// policy activates mid-session.
extension AppDelegate {
    /// Installs the managed-policy transition observer once at startup.
    func installManagedPolicyEnforcement() {
        guard managedPolicyEnforcementObserver == nil else { return }
        managedPolicyEnforcementObserver = ManagedPolicyEnforcementObserver(
            enforceBrowserPolicy: { [weak self] in
                self?.closeBrowserPanelsForManagedPolicy()
            },
            enforceBrowserURLAllowlistPolicy: { [weak self] in
                self?.enforceBrowserURLAllowlistPolicy()
            },
            enforceRemoteControlPolicy: {
                // syncToSettings() tears the mobile host down under the
                // policy (including live connections) and re-arms it when
                // the policy lifts.
                MobileHostService.shared.syncToSettings()
            },
            enforceCloudPolicy: { [weak self] in
                self?.applyManagedCloudPolicy()
            },
            enforceRemoteConnectionsPolicy: { [weak self] in
                self?.endRemoteConnectionsForManagedPolicy()
            },
            enforceComputerUsePolicy: { [weak self] in
                self?.applyManagedComputerUsePolicy()
            }
        )
    }

    /// `DisableComputerUse` transitions, both directions: activation stops the
    /// helper (the spawn policy already withholds the tools from new agent
    /// launches); a lift re-applies the user's own setting.
    func applyManagedComputerUsePolicy() {
        guard let service = computerUseRuntimeService else { return }
        let catalog = settingsRuntime?.catalog ?? SettingCatalog()
        let store = settingsRuntime?.jsonStore
            ?? JSONConfigStore(fileURL: CmuxConfigLocation().userConfigFile)
        let userEnabled = store.snapshotValue(for: catalog.computerUse.enabled)
        Task { @MainActor in
            // `setEnabled` applies the policy itself; passing the user's value
            // keeps a lift symmetrical with activation.
            await service.setEnabled(userEnabled)
        }
    }

    /// `DisableAutoUpdate`: a manual "Check for Updates…" explains the managed
    /// state instead of silently doing nothing. Returns true when the check
    /// may proceed.
    func managedAutoUpdateAllowsCheck() -> Bool {
        guard ManagedDevicePolicy().isEnforced(.disableAutoUpdate) else { return true }
        let alert = NSAlert()
        alert.messageText = String(
            localized: "managedPolicy.autoUpdate.disabled",
            defaultValue: "Software updates are managed by your organization."
        )
        alert.informativeText = String(
            localized: "managedPolicy.autoUpdate.disabledDetail",
            defaultValue: "cmux does not check for or install updates on this Mac. Your organization deploys new versions."
        )
        alert.alertStyle = .informational
        alert.runModal()
        return false
    }

    /// `DisableRemoteConnections` activation. Every live cmux-created remote
    /// connection ends: remote workspaces (SSH, Mosh, and Cloud attachments)
    /// disconnect and drop their configuration so no reconnect path can
    /// redial, remote tmux mirrors detach and close, and their SSH control
    /// masters exit. Remote tmux sessions stay alive on their hosts; only
    /// cmux's connections to them end. The per-call gates
    /// (`Workspace.configureRemoteConnection`, `reconnectRemoteConnection`,
    /// the remote-tmux socket verbs) refuse anything new while the policy is
    /// forced, and read the resolver live once it lifts.
    func endRemoteConnectionsForManagedPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs where workspace.isRemoteWorkspace {
                workspace.disconnectRemoteConnection(
                    clearConfiguration: true,
                    disconnectedDetail: ManagedRemoteConnectionsPolicy.disabledMessage
                )
            }
        }
        remoteTmuxController.detachAllForManagedPolicy()
    }

    /// `DisableCloud` transitions, both directions. Activation ends Cloud
    /// access through the same path sign-out uses — Cloud workspaces, their
    /// closed-history records, in-flight launcher children, and the managed
    /// VPN configuration — after the surface registry drops its providers and
    /// private-network links. Lifting the policy restarts Cloud discovery so
    /// the sidebar and surface catalog return without a relaunch; every
    /// per-call gate (`CloudMachinesFeature`, `VMClient`, the tunnel
    /// coordinator, the socket verbs) already reads the live policy.
    /// Transitions are serialized on ``managedCloudPolicyTask`` and the policy
    /// is re-read after every suspension, so a lift that arrives while a
    /// teardown is still running cannot be overtaken by it.
    func applyManagedCloudPolicy() {
        let previous = managedCloudPolicyTask
        managedCloudPolicyTask = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return }
            guard ManagedDevicePolicy().isEnforced(.disableCloud) else {
                CmuxTuiSurfaceProviderRegistry.shared.start(catalog: .shared)
                return
            }
            await CmuxTuiSurfaceProviderRegistry.shared.accessDidEnd()
            guard ManagedDevicePolicy().isEnforced(.disableCloud) else {
                // The profile was removed mid-teardown: Cloud is allowed again,
                // so restart discovery instead of ending live access.
                CmuxTuiSurfaceProviderRegistry.shared.start(catalog: .shared)
                return
            }
            self.endCloudVMAccess(reason: .managedPolicy)
            // endCloudVMAccess starts VPN removal too. Discovery cannot be
            // re-armed until that part of the same transition has drained.
            await self.cloudTunnelTeardownTask?.value
        }
    }

    /// Closes every live browser pane — main area and Docks, across all
    /// windows — when `DisableEmbeddedBrowser` activates while cmux runs.
    func closeBrowserPanelsForManagedPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                let browserPanelIds = workspace.panels.compactMap { id, panel in
                    panel is BrowserPanel ? id : nil
                }
                for panelId in browserPanelIds {
                    _ = workspace.closePanel(panelId, force: true)
                }
                if let dock = workspace._dockSplit {
                    closeDockBrowserPanelsForManagedPolicy(dock)
                }
            }
            for dock in manager.liveWindowDockStores {
                closeDockBrowserPanelsForManagedPolicy(dock)
            }
        }
    }

    /// Re-evaluates every live browser document when the effective allowlist
    /// changes. The panel/delegate boundary renders the localized blocked page
    /// and also traverses popup windows.
    func enforceBrowserURLAllowlistPolicy() {
        for manager in allTabManagersForManagedPolicyEnforcement() {
            for workspace in manager.tabs {
                for panel in workspace.panels.values {
                    (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                }
                if let dock = workspace._dockSplit {
                    dock.forEachPanel { _, panel in
                        (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                    }
                }
            }
            for dock in manager.liveWindowDockStores {
                dock.forEachPanel { _, panel in
                    (panel as? BrowserPanel)?.enforceURLAllowlistPolicy()
                }
            }
        }
    }

    private func closeDockBrowserPanelsForManagedPolicy(_ store: DockSplitStore) {
        var browserPanelIds: [UUID] = []
        store.forEachPanel { panelId, panel in
            if panel is BrowserPanel { browserPanelIds.append(panelId) }
        }
        for panelId in browserPanelIds {
            _ = store.closePanel(panelId, force: true)
        }
    }

    private func allTabManagersForManagedPolicyEnforcement() -> [TabManager] {
        var managers: [TabManager] = []
        for context in mainWindowContexts.values {
            managers.append(context.tabManager)
        }
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers
    }
}
