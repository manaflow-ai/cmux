import Foundation

/// Runtime enforcement for MDM managed policies (`DisableEmbeddedBrowser`,
/// `DisableRemoteControl`): installs the transition observer and closes live
/// browser panes when the browser policy activates mid-session.
extension AppDelegate {
    /// Installs the managed-policy transition observer once at startup.
    func installManagedPolicyEnforcement() {
        guard managedPolicyEnforcementObserver == nil else { return }
        managedPolicyEnforcementObserver = ManagedPolicyEnforcementObserver(
            enforceBrowserPolicy: { [weak self] in
                self?.closeBrowserPanelsForManagedPolicy()
            },
            enforceRemoteControlPolicy: {
                // syncToSettings() tears the mobile host down under the
                // policy (including live connections) and re-arms it when
                // the policy lifts.
                MobileHostService.shared.syncToSettings()
            }
        )
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
