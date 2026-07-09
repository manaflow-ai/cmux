import Foundation

extension AppDelegate {
    @MainActor
    func syncResolvedIconImagesForCurrentAppearance() {
        var seenManagers = Set<ObjectIdentifier>()
        for context in mainWindowContexts.values {
            let identifier = ObjectIdentifier(context.tabManager)
            guard seenManagers.insert(identifier).inserted else { continue }
            context.tabManager.syncTerminalTabAgentIconAssetsForAllWorkspaces()
        }
        for dockStore in DockSplitStore.liveStores {
            dockStore.syncTerminalTabAgentIconAssetsForAllTerminalPanels()
        }
    }
}

extension TabManager {
    @MainActor
    func syncTerminalTabAgentIconAssetsForAllWorkspaces() {
        for workspace in tabs {
            workspace.syncTerminalTabAgentIconAssetsForAllTerminalPanels()
        }
    }
}
