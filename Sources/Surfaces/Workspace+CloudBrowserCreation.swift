import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension Workspace {
    struct CloudBrowserCreationRoute {
        let machine: SurfaceMachineID
        let remoteWorkspaceID: String?
        let screenID: String?
        let paneID: String?
        let url: URL
    }

    /// Returns a remote browser target only for a bound Cloud workspace. SSH
    /// workspaces continue through their existing browser path.
    func cloudBrowserCreationRoute(sourcePanelID: UUID?, requestedURL: URL?) -> CloudBrowserCreationRoute? {
        guard let binding = cloudVMBinding else { return nil }
        let machine = SurfaceMachineID(rawValue: binding.vmID)
        guard machine.cloudMachineID != nil,
              SurfaceCatalog.shared.provider(for: machine) is CmuxTuiSurfaceProvider else { return nil }
        let boundRemoteWorkspaceID = binding.remoteWorkspaceID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .flatMap { $0.isEmpty ? nil : $0 }
        let sourceView: SurfaceRemoteView? = sourcePanelID.flatMap { panelID in
            guard let projection = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: panelID),
                  projection.resource.machine == machine,
                  let resource = SurfaceCatalog.shared.resources[projection.resource] else { return nil }
            if let tabID = projection.remoteTabID {
                return resource.remoteViews?.first(where: { $0.tabID == tabID })
            }
            if let boundRemoteWorkspaceID {
                return resource.remoteViews?.first(where: { $0.workspace.id == boundRemoteWorkspaceID })
            }
            return resource.remoteViews?.first
        }
        let remoteWorkspaceID = boundRemoteWorkspaceID
            ?? sourceView?.workspace.id
            ?? (SurfaceCatalog.shared.provider(for: machine) as? CmuxTuiSurfaceProvider)?.info.remoteWorkspaces?.first(where: \.focused)?.id
        guard let remoteWorkspaceID, !remoteWorkspaceID.isEmpty else { return nil }
        let url = requestedURL ?? URL(string: "about:blank")!
        return CloudBrowserCreationRoute(
            machine: machine,
            remoteWorkspaceID: remoteWorkspaceID,
            screenID: sourceView?.screenID,
            paneID: sourceView?.paneID,
            url: url
        )
    }

    /// Starts the remote create after the native tab has been inserted. The
    /// placeholder is kept free of a local URL until the daemon receipt binds it.
    func startCloudBrowserCreation(panel: BrowserPanel, route: CloudBrowserCreationRoute, name: String? = nil) {
        let catalog = SurfaceCatalog.shared
        guard let provider = catalog.provider(for: route.machine) as? CmuxTuiSurfaceProvider else { return }
        let mutation = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: route.machine)
        pendingCloudBrowserPanelIDs.insert(panel.id)
        let requestID = UUID().uuidString.lowercased()
        let task = Task { @MainActor [weak self, weak panel, weak provider] in
            guard let self, let panel, let provider else { return }
            defer {
                self.cloudBrowserCreationTasks.removeValue(forKey: panel.id)
                self.pendingCloudBrowserPanelIDs.remove(panel.id)
                catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(mutation, on: route.machine, catalog: catalog)
                self.cloudLayoutDidChange()
            }
            do {
                guard !Task.isCancelled, self.panels[panel.id] === panel else { throw CancellationError() }
                let created = try await provider.createBrowser(
                    url: route.url,
                    name: name,
                    remoteWorkspaceID: route.remoteWorkspaceID,
                    screenID: route.screenID,
                    paneID: route.paneID,
                    idempotencyKey: "cmux-cloud-browser-\(requestID)",
                    correlationKey: "cmux-cloud-browser-\(requestID)"
                )
                guard !Task.isCancelled, self.panels[panel.id] === panel,
                      let remoteView = created.remoteViews?.first else { throw CancellationError() }
                if ["http", "https"].contains(route.url.scheme?.lowercased() ?? "") {
                    guard provider.configureBrowser(panel, url: route.url, resourceID: created.id) else {
                        throw CmuxTuiSurfaceProvider.ProviderError.localForwardURLUnavailable
                    }
                } else if route.url.scheme?.lowercased() == "about" {
                    panel.cloudAccess.retainResource(created.id)
                } else {
                    throw CmuxTuiSurfaceProvider.ProviderError.localForwardURLUnavailable
                }
                catalog.endProjections(panelID: panel.id, reason: .replaced)
                catalog.record(SurfaceProjection(
                    resource: created.id,
                    workspaceID: self.id,
                    panelID: panel.id,
                    remoteWorkspaceID: remoteView.workspace.id,
                    remoteTabID: remoteView.tabID
                ))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.panels[panel.id] === panel else { return }
                panel.cloudAccess.showUnavailable(String(localized: "cloud.browser.creationUnavailable", defaultValue: "Cloud browsers are unavailable on this machine. Refresh the machine and retry."))
            }
        }
        cloudBrowserCreationTasks[panel.id] = task
    }
}
