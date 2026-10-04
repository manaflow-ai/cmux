import CmuxCloud
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import WebKit

extension BrowserPanel {
    /// Keeps the browser-owned readiness callback installed while a committed
    /// WebKit document is rebound to a new same-VM route.
    func bindCloudBrowserNavigation() {
        cloudAccess.automaticallyNavigate { [weak self] url in
            guard let self, !self.isClosingWebViewLifecycle else { return }
            _ = self.navigate(to: url)
        }
    }

    /// Activates an admitted Cloud route independently of the SwiftUI host.
    /// Callers validate resource ownership before reaching this boundary.
    func configureCloudBrowser(model: CloudPortAccessModel, url: URL, resourceID: SurfaceResourceID? = nil) {
        guard !isClosingWebViewLifecycle else { return }
        webView.stopLoading()
        if let machineID = (resourceID ?? cloudAccess.resourceID)?.machine.rawValue ?? cloudBrowserMachineID {
            prepareCloudBrowserStore(machineID: machineID)
        }
        showCloudAddress(url)
        // A cached model can navigate synchronously. Its machine/profile store
        // must be installed first, including on reconfiguration and duplication.
        cloudAccess.configure(model: model, url: url, resourceID: resourceID)
        bindCloudBrowserNavigation()
        model.connect()
    }

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

    /// The owning team persisted with ``cloudResourceForSession``: the
    /// machine's provider team, else the restored team, else the selected team.
    var cloudTeamIDForSession: String? {
        guard let machineID = cloudResourceForSession?.machine.cloudMachineID else { return nil }
        if let owner = CmuxTuiSurfaceProviderRegistry.shared.ownerTeamID(forMachineID: machineID) {
            return owner
        }
        return restoredCloudTeamID ?? WorkspaceCloudVMBinding.owningTeamID(forVMID: machineID, previous: nil)
    }

    /// Restore by stable resource identity before loading any saved address.
    /// A stale/unknown provider leaves an owned placeholder, never a local page.
    func restoreCloudResource(_ resource: SurfaceResourceID, preferredURL: URL? = nil,
                             activate: Bool = true) {
        pendingCloudRestoreURL = preferredURL
        let catalog = SurfaceCatalog.shared
        let isGlobalDock = DockSplitStore.liveStore(containingPanel: id)?.scope == .global
        do {
            if !isGlobalDock {
                try catalog.validateOwnership(of: [resource], at: .workspace(id: workspaceId, placement: .tab))
            }
        }
        catch { cloudAccess.showUnavailable(SurfaceTransferRejection.cloudMachineMismatch.message); return }
        cloudAccess.retainResource(resource)
        retainTransferredSurfaceMachine(resource.machine)
        catalog.restore([SurfaceProjectionRecord(panelID: id, resource: resource)], workspaceID: workspaceId)
        guard activate else { return }
        guard let provider = catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider,
              let known = catalog.resources[resource] else {
            showCloudRestoreUnavailable(
                resource,
                message: String(localized: "cloud.display.restoreUnavailable", defaultValue: "This Cloud display or browser is unavailable. Refresh its machine to reconnect.")
            )
            return
        }
        switch CloudPortRoutePlan.plan(resource: known, privateAddress: provider.info.privateAddress) {
        case .privateDirect(let raw):
            if let url = URL(string: raw) {
                let configured = provider.configureBrowser(self,
                    url: Self.cloudRestoredURL(pendingCloudRestoreURL, on: url, isDisplay: resource.kind == .display),
                    resourceID: resource)
                if configured { pendingCloudRestoreURL = nil }
            }
        case .unsupported(let message):
            // The provider owns the retry because it can refresh the machine's
            // private address before trying to materialize the saved projection.
            // This is the same recovery path used by a live port row.
            provider.showPortUnavailable(message, resourceID: resource, browser: self)
        }
    }

    /// Keep a restored Cloud pane recoverable while its provider is being
    /// discovered. Session restore can run before the machine list has
    /// registered the provider or before its first resource snapshot arrives.
    private func showCloudRestoreUnavailable(_ resource: SurfaceResourceID, message: String) {
        let preferredURL = pendingCloudRestoreURL
        cloudAccess.showUnavailable(message) { [weak self] request in
            guard let self else { return }
            _ = await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true)
            guard self.cloudAccess.isCurrentUnavailableRetry(request) else { return }
            self.restoreCloudResource(resource, preferredURL: preferredURL)
        }
    }

    private static func cloudRestoredURL(_ preferred: URL?, on target: URL, isDisplay: Bool = false) -> URL {
        guard let preferred, var components = URLComponents(url: target, resolvingAgainstBaseURL: false),
              let saved = URLComponents(url: preferred, resolvingAgainstBaseURL: false) else { return target }
        if !saved.percentEncodedPath.isEmpty { components.percentEncodedPath = saved.percentEncodedPath }
        if isDisplay {
            let allowed = Set(["path", "autoconnect", "resize", "reconnect", "reconnect_delay"])
            let safeItems = (saved.queryItems ?? []).filter { allowed.contains($0.name.lowercased()) }
            if !safeItems.isEmpty { components.queryItems = safeItems }
        } else {
            components.percentEncodedQuery = saved.percentEncodedQuery
            components.percentEncodedFragment = saved.percentEncodedFragment
        }
        return components.url ?? target
    }

    func cloudRestoreURL(on target: URL) -> URL {
        Self.cloudRestoredURL(
            pendingCloudRestoreURL ?? currentURLForTabDuplication,
            on: target,
            isDisplay: cloudResourceForDuplication?.kind == .display
        )
    }

    /// The provider whose machine serves `url` at its private address.
    ///
    /// SSH machines all use this Mac's loopback as their private address, so
    /// a loopback URL routes only to the machine that owns this browser.
    func privateAddressRouteProvider(for url: URL) -> CmuxTuiSurfaceProvider? {
        let catalog = SurfaceCatalog.shared
        let addresses = catalog.machines.compactMapValues(\.privateAddress)
        let machine = PrivateAddressRouteSelector<SurfaceMachineID>().machine(
            forHost: url.host,
            owner: privateAddressRouteOwner,
            addresses: addresses
        )
        return machine.flatMap { catalog.provider(for: $0) as? CmuxTuiSurfaceProvider }
    }

    /// The machine this browser belongs to: its current cloud route, or the
    /// machine that owns its workspace.
    private var privateAddressRouteOwner: SurfaceMachineID? {
        if let machine = cloudResourceForDuplication?.machine { return machine }
        if let machineID = cloudBrowserMachineID { return SurfaceMachineID(rawValue: machineID) }
        return AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.tabs
            .first { $0.id == workspaceId }?
            .surfaceOwnershipPolicy.cloudMachine
    }

    @discardableResult
    func rebindCloudRouteIfNeeded(to url: URL) -> Bool {
        guard let provider = privateAddressRouteProvider(for: url) else {
            return false
        }
        return provider.configureBrowser(self, url: url, preserveCurrentNavigation: true)
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
