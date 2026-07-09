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
