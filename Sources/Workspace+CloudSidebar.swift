import AppKit
import Bonsplit

extension Workspace {
    func cloudSidebarRevealTarget(forPanel panelID: UUID? = nil) -> CloudSidebarRevealTarget? {
        if let panelID, panels[panelID] == nil { return nil }
        return CloudSidebarRevealTarget(
            projection: panelID.flatMap { SurfaceCatalog.shared.projection(forPanel: $0) },
            binding: cloudVMBinding,
            managedCloudVMID: remoteConfiguration?.managedCloudVMID
        )
    }

    /// All entrypoints use the clicked workspace's window and catalog identity.
    @discardableResult
    func focusInCloudSidebar(panelID: UUID? = nil) -> Bool {
        guard let target = cloudSidebarRevealTarget(forPanel: panelID),
              let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: id),
              let context = app.mainWindowContext(for: manager),
              let state = context.fileExplorerState,
              let window = context.window,
              context.keyboardFocusCoordinator.canFocusRightSidebar(mode: .machines) else { return false }
        state.cloudSidebarNavigation.reveal(target)
        return app.focusRightSidebarInActiveMainWindow(
            mode: .machines,
            focusFirstItem: false,
            preferredWindow: window
        )
    }

    func focusInCloudSidebarMenuItem(panelID: UUID? = nil) -> NSMenuItem? {
        guard CloudMachinesFeature.isEnabled,
              cloudSidebarRevealTarget(forPanel: panelID) != nil else { return nil }
        let item = CloudTreeMenuItem(
            title: String(localized: "contextMenu.focusInCloudSidebar", defaultValue: "Focus in Cloud Sidebar")
        ) { [weak self] in
            _ = self?.focusInCloudSidebar(panelID: panelID)
        }
        item.image = NSImage(systemSymbolName: "cloud", accessibilityDescription: nil)
        return item
    }

    func configureCloudSidebarContextMenu() {
        bonsplitController.tabContextMenuItemsProvider = { [weak self] tabID, _ in
            guard let self, let panelID = self.panelIdFromSurfaceId(tabID),
                  let item = self.focusInCloudSidebarMenuItem(panelID: panelID) else { return [] }
            return [item]
        }
    }
}
