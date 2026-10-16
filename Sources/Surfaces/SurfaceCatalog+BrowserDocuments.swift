import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    struct CloudBrowserDocument {
        var url: URL
        var title: String
        var remoteTabID: String
        var revision: UInt64
    }

    /// WebKit owns a native Cloud browser's current document. Publishing it must
    /// neither navigate the daemon's separate browser nor scan/materialize panes.
    func cloudBrowserDocumentDidChange(_ browser: BrowserPanel) {
        guard let resourceID = browser.cloudAccess.resourceID,
              resourceID.machine.cloudMachineID != nil, resourceID.kind == .browser,
              !resourceID.isForwardedPort,
              let projection = projection(forPanel: browser.id), projection.resource == resourceID,
              projection.workspaceID == browser.workspaceId,
              let resource = resources[projection.resource],
              resource.machine.cloudMachineID != nil, resource.kind == .browser,
              !resource.id.isForwardedPort,
              let tabID = projection.remoteTabID,
              resource.remoteViews?.contains(where: { $0.tabID == tabID }) == true,
              let provider = provider(for: resource.machine) as? CmuxTuiSurfaceProvider,
              provider.isRegisteredInCatalog(), !provider.hasLostAccess,
              let url = browser.currentURL,
              url == SurfacePaneFactory.blankURL
                  || (["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host?.isEmpty == false) else { return }
        let title = url == SurfacePaneFactory.blankURL || browser.pageTitle.isEmpty
            ? url.absoluteString : browser.pageTitle
        let previous = cloudBrowserDocuments[resource.id]?[browser.id]
        guard previous?.url != url || previous?.title != title else { return }
        cloudBrowserDocumentRevision &+= 1
        cloudBrowserDocuments[resource.id, default: [:]][browser.id] = CloudBrowserDocument(
            url: url, title: title, remoteTabID: tabID, revision: cloudBrowserDocumentRevision
        )
        notifyChange(for: resource.machine)
    }

    func resourceWithCloudBrowserDocument(_ resource: SurfaceResource) -> SurfaceResource {
        guard resource.lifecycle != .unavailable,
              let documents = cloudBrowserDocuments[resource.id],
              let document = documents.values.filter({ document in
                  resource.remoteViews?.contains(where: { $0.tabID == document.remoteTabID }) == true
              }).max(by: { $0.revision < $1.revision }) else { return resource }
        var result = resource
        result.url = document.url.absoluteString
        result.detail = result.url
        result.title = document.title
        return result
    }
}
