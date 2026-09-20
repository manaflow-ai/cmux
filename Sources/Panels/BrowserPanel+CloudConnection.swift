import Foundation
import WebKit

extension BrowserPanel {
    var cloudResourceForSession: SurfaceResourceID? {
        let resource = SurfaceCatalog.shared.projectionRecord(forPanel: id)?.resource
        return resource?.machine.isLocal == false ? resource : cloudAccess.resourceID
    }

    /// Restore by stable resource identity before loading any saved address.
    /// A stale/unknown provider leaves an owned placeholder, never a local page.
    func restoreCloudResource(_ resource: SurfaceResourceID) {
        let catalog = SurfaceCatalog.shared
        do { try catalog.validateOwnership(of: [resource], at: .workspace(id: workspaceId, placement: .tab)) }
        catch { cloudAccess.showUnavailable(SurfaceTransferRejection.cloudMachineMismatch.message); return }
        cloudAccess.retainResource(resource)
        retainTransferredSurfaceMachine(resource.machine)
        catalog.restore([SurfaceProjectionRecord(panelID: id, resource: resource)], workspaceID: workspaceId)
        guard let provider = catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider,
              let known = catalog.resources[resource] else {
            cloudAccess.showUnavailable(String(localized: "cloud.display.restoreUnavailable", defaultValue: "This Cloud display or browser is unavailable. Refresh its machine to reconnect."))
            return
        }
        switch CloudPortRoutePlan.plan(resource: known, privateAddress: provider.info.privateAddress) {
        case .privateDirect(let raw):
            if let url = URL(string: raw) { provider.configureBrowser(self, url: url, resourceID: resource) }
        case .unsupported(let message): cloudAccess.showUnavailable(message)
        }
    }

    /// Cloud panes use their own persistent data store so configuring one VM cannot reroute another.
    func prepareCloudBrowserStore(machineID: String) {
        let identifier = CloudBrowserRouting.storeID(panelID: id, profileID: profileID, machineID: machineID)
        guard cloudBrowserStoreIdentity != identifier else { return }
        cloudBrowserMachineID = machineID
        cloudBrowserStoreIdentity = identifier
        cloudBrowserProxyEndpoint = nil
        websiteDataStore = preservesExplicitEphemeralWebsiteDataStore
            ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: identifier)
        // The route may still be connecting. Do not construct its WebView with
        // an unconfigured store: its first network session must own the proxy.
    }

    /// Apply proxy credentials before the first request, with no system-network fallback.
    func prepareCloudBrowserNavigation() {
        guard let endpoint = cloudAccess.model?.browserProxy,
              let address = cloudAccess.model?.target.host else { return }
        guard endpoint != cloudBrowserProxyEndpoint else { return }
        cloudBrowserProxyEndpoint = endpoint
        websiteDataStore.proxyConfigurations = [CloudBrowserRouting.configuration(endpoint: endpoint, address: address)]
        CloudBrowserRouting.installWebSocketBridge(endpoint: endpoint, address: address, on: webView)
        if webView.configuration.websiteDataStore !== websiteDataStore {
            replaceWebViewPreservingState(from: webView, websiteDataStore: websiteDataStore,
                                         reason: "cloud_browser_route", restoreAfterReplacement: false)
        }
    }

    func installCloudDesktopConnectionObserver(on webView: WKWebView) {
        let isCurrent = webViewObservationValidator(for: webView)
        CloudDesktopConnectionObserver.install(on: webView, onConnecting: { [weak self] url in
            guard let self, isCurrent() else { return }
            self.cloudAccess.desktopConnectionIsConnecting(url: url)
        }) { [weak self] url, isConnected in
            guard let self, isCurrent() else { return }
            self.cloudAccess.desktopConnectionDidChange(url: url, isConnected: isConnected)
        }
    }

    func preferredURLStringForSessionSnapshot() -> String? {
        if let serviceURL = cloudAccess.sessionURL(currentURL: currentURL) { return serviceURL.absoluteString }
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: webView.url),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        if let currentURL,
           let value = Self.serializableSessionHistoryURLString(currentURL) {
            return value
        }
        return nil
    }
}
