import Foundation
import WebKit

extension BrowserPanel {
    /// Leaving a Cloud resource for a user-owned external page ends only this
    /// local projection. The `.replaced` reason keeps a navigation from
    /// editing the remote workspace layout while removing stale restore
    /// provenance from this panel.
    func leaveCloudResourceForLocalNavigation() {
        pendingCloudRestoreURL = nil
        if retainsCloudResourceForDuplication {
            SurfaceCatalog.shared.endProjections(panelID: id, reason: .replaced)
        }
        cloudAccess.leave()
    }

    /// The catalog projection remains authoritative while a Cloud pane is an
    /// unavailable placeholder and before its provider has configured the
    /// browser. Deliberate external navigation removes that projection first.
    var cloudResourceForDuplication: SurfaceResourceID? {
        if let resource = cloudAccess.resourceID, !resource.machine.isLocal {
            return resource
        }
        let resource = SurfaceCatalog.shared.projectionRecord(forPanel: id)?.resource
        return resource?.machine.isLocal == false ? resource : nil
    }

    var retainsCloudResourceForDuplication: Bool {
        cloudAccess.model != nil || cloudResourceForDuplication != nil
    }

    var cloudResourceForSession: SurfaceResourceID? {
        guard retainsCloudResourceForDuplication else { return nil }
        return cloudResourceForDuplication
    }

    /// Restore by stable resource identity before loading any saved address.
    /// A stale/unknown provider leaves an owned placeholder, never a local page.
    func restoreCloudResource(_ resource: SurfaceResourceID, preferredURL: URL? = nil) {
        pendingCloudRestoreURL = preferredURL
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
            if let url = URL(string: raw) {
                let configured = provider.configureBrowser(
                    self,
                    url: Self.cloudRestoredURL(pendingCloudRestoreURL, on: url),
                    resourceID: resource
                )
                if configured { pendingCloudRestoreURL = nil }
            }
        case .unsupported(let message): cloudAccess.showUnavailable(message)
        }
    }

    private static func cloudRestoredURL(_ preferred: URL?, on target: URL) -> URL {
        guard let preferred, var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              let saved = URLComponents(url: preferred, resolvingAgainstBaseURL: false) else { return target }
        components.path = saved.path.isEmpty ? components.path : saved.path
        components.query = saved.query
        components.fragment = saved.fragment
        return components.url ?? target
    }

    func cloudRestoreURL(on target: URL) -> URL {
        Self.cloudRestoredURL(pendingCloudRestoreURL ?? currentURLForTabDuplication, on: target)
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
