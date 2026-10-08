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
            if var request = self.pendingCloudNavigationRequest {
                request.url = url
                self.pendingCloudNavigationRequest = request
            }
            guard let model = self.cloudAccess.model, model.route == .loopback else {
                _ = self.navigate(to: url)
                return
            }
            Task { @MainActor [weak self, weak model] in
                guard let self, let model, !self.isClosingWebViewLifecycle else { return }
                self.prepareCloudBrowserNavigation()
                let generation = UUID()
                self.cloudLoopbackProtectionGeneration = generation
                self.cloudLoopbackScriptGeneration += 1
                let scriptGeneration = self.cloudLoopbackScriptGeneration
                do {
                    try await self.installManagedSSHLoopbackProtection(
                        for: url, generation: generation, scriptGeneration: scriptGeneration
                    )
                    guard self.cloudLoopbackProtectionGeneration == generation else { return }
                    guard self.cloudAccess.model === model, self.cloudAccess.owns(url) else { return }
                    _ = self.navigate(to: url)
                } catch {
                    guard self.cloudLoopbackProtectionGeneration == generation,
                          self.cloudAccess.model === model, self.cloudAccess.owns(url) else { return }
                    self.cloudAccess.showUnavailable(String(
                        localized: "cloud.portAccess.loopbackProtectionUnavailable",
                        defaultValue: "cmux could not safely open this SSH loopback preview. Reload to try again."
                    ))
                    await model.stop()
                }
            }
        }
    }

    func installManagedSSHLoopbackProtection(for url: URL, generation: UUID, scriptGeneration: Int) async throws {
        guard let port = url.port, port > 0, port <= Int(UInt16.max),
              let store = WKContentRuleListStore.default() else {
            throw CloudMachineLink.LinkError.spawnFailed("The SSH browser protection rule could not be prepared.")
        }
        let schemes = ["http", "https", "ws", "wss"]
        let blockedHosts = [
            ("localhost\\.?", true), (".*\\.localhost\\.?", true),
            ("127\\.", false), ("0\\.0\\.0\\.0", true),
            ("\\[::1\\]", true), ("\\[0:0:0:0:0:0:0:1\\]", true),
            ("\\[::ffff:", false), ("[0-9]+", true)
        ]
        var rules: [[String: Any]] = []
        for scheme in schemes {
            for (host, needsPortAndPath) in blockedHosts {
                let suffix = needsPortAndPath ? "(:[0-9]+)?/" : ""
                rules.append([
                    "trigger": ["url-filter": "^\(scheme)://\(host)\(suffix)"],
                    "action": ["type": "block"]
                ])
            }
        }
        for scheme in ["http", "ws"] {
            rules.append([
                "trigger": ["url-filter": "^\(scheme)://127\\.0\\.0\\.1:\(port)/"],
                "action": ["type": "ignore-previous-rules"]
            ])
        }
        let encodedRules = try JSONSerialization.data(withJSONObject: rules)
        guard let ruleJSON = String(data: encodedRules, encoding: .utf8) else {
            throw CloudMachineLink.LinkError.spawnFailed("The SSH browser protection rule could not be encoded.")
        }
        // The rule store is persistent. A stable per-port identifier lets a
        // replacement update the same entry instead of accumulating one UUID
        // for every navigation in the user's WebKit data directory.
        let identifier = "cmux.ssh-loopback.\(port)"
        if let oldIdentifier = cloudLoopbackContentRuleListIdentifier,
           oldIdentifier != identifier {
            await removeManagedSSHLoopbackRule(from: store, identifier: oldIdentifier)
        }
        // Removing the existing stored entry before compiling avoids a stale
        // rule-list cache when WebKit rejects a duplicate identifier.
        await removeManagedSSHLoopbackRule(from: store, identifier: identifier)
        let ruleList: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: ruleJSON) { rule, error in
                if let error { continuation.resume(throwing: error) }
                else if let rule { continuation.resume(returning: rule) }
                else { continuation.resume(throwing: CloudMachineLink.LinkError.spawnFailed("The SSH browser protection rule could not be compiled.")) }
            }
        }
        guard cloudLoopbackProtectionGeneration == generation,
              cloudAccess.model?.route == .loopback,
              cloudAccess.owns(url) else { return }
        let controller = webView.configuration.userContentController
        if let oldRule = cloudLoopbackContentRuleList { controller.remove(oldRule) }
        controller.add(ruleList)
        cloudLoopbackContentRuleList = ruleList
        cloudLoopbackContentRuleListIdentifier = identifier
        if let model = cloudAccess.model {
            let scriptConfigurationKey = "ssh:\(model.target.host.lowercased()):\(model.target.port):\(port)"
            if cloudLoopbackScriptConfigurationKey != scriptConfigurationKey {
                let script = WKUserScript(
                    source: RemoteLoopbackRuntimeBridge.scriptSource(
                        aliasHost: "127.0.0.1", aliasPort: port,
                        remoteHost: model.target.host, remotePort: model.target.port,
                        generation: scriptGeneration
                    ),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false
                )
                controller.addUserScript(script)
                cloudLoopbackRuntimeBridgeScript = script
                cloudLoopbackScriptConfigurationKey = scriptConfigurationKey
            }
        }
    }

    private func removeManagedSSHLoopbackRule(from store: WKContentRuleListStore, identifier: String) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeContentRuleList(forIdentifier: identifier) { _ in continuation.resume() }
        }
    }

    func removeManagedSSHLoopbackProtection(restoreGeneralBridge: Bool = false) {
        cloudLoopbackProtectionGeneration = UUID()
        cloudLoopbackScriptGeneration += 1
        let controller = webView.configuration.userContentController
        if let ruleList = cloudLoopbackContentRuleList { controller.remove(ruleList) }
        if let identifier = cloudLoopbackContentRuleListIdentifier,
           let store = WKContentRuleListStore.default() {
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
        if cloudLoopbackScriptConfigurationKey?.hasPrefix("ssh:") == true {
            let enabled = restoreGeneralBridge ? "true" : "false"
            let aliasHost = restoreGeneralBridge ? RemoteLoopbackProxyAlias.aliasHost : "127.0.0.1"
            webView.evaluateJavaScript("""
            if (window.__cmuxRemoteLoopbackBridgeConfig) {
              window.__cmuxRemoteLoopbackBridgeConfig.enabled = \(enabled);
            window.__cmuxRemoteLoopbackBridgeConfig.aliasHost = '\(aliasHost)';
            }
            """)
            let script = WKUserScript(
                source: RemoteLoopbackRuntimeBridge.scriptSource(
                    aliasHost: aliasHost, enabled: restoreGeneralBridge, generation: cloudLoopbackScriptGeneration
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            controller.addUserScript(script)
            cloudLoopbackRuntimeBridgeScript = script
            cloudLoopbackScriptConfigurationKey = nil
        }
        cloudLoopbackContentRuleList = nil
        cloudLoopbackContentRuleListIdentifier = nil
    }

    /// Activates an admitted Cloud route independently of the SwiftUI host.
    /// Callers validate resource ownership before reaching this boundary.
    func configureCloudBrowser(model: CloudPortAccessModel, url: URL, resourceID: SurfaceResourceID? = nil,
                               request: URLRequest? = nil) {
        guard !isClosingWebViewLifecycle else { return }
        if model.route != .loopback { removeManagedSSHLoopbackProtection(restoreGeneralBridge: true) }
        webView.stopLoading()
        pendingCloudNavigationRequest = request
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
        removeManagedSSHLoopbackProtection()
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
                             activate: Bool = true, automaticRetriesRemaining: Int = 2) {
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
        guard let provider = catalog.provider(for: resource.machine) as? CmuxTuiSurfaceProvider else {
            showCloudRestoreUnavailable(
                resource,
                message: String(localized: "cloud.display.restoreUnavailable", defaultValue: "This Cloud display or browser is unavailable. Refresh its machine to reconnect."),
                automaticRetriesRemaining: automaticRetriesRemaining
            )
            return
        }
        guard let known = catalog.resources[resource] else {
            // The provider can be registered before its first port/display
            // snapshot. Force that provider's metadata and graph refresh so a
            // restored port is discovered before retrying materialization.
            showCloudRestoreUnavailable(
                resource,
                provider: provider,
                message: String(localized: "cloud.display.restoreUnavailable", defaultValue: "This Cloud display or browser is unavailable. Refresh its machine to reconnect."),
                automaticRetriesRemaining: automaticRetriesRemaining
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
    private func showCloudRestoreUnavailable(
        _ resource: SurfaceResourceID,
        provider: CmuxTuiSurfaceProvider? = nil,
        message: String,
        automaticRetriesRemaining: Int
    ) {
        let preferredURL = pendingCloudRestoreURL
        let recover: @MainActor (UInt64) async -> Void = { [weak self] request in
            guard let self else { return }
            if let provider {
                provider.requestPortDiscovery()
                try? await provider.refreshPortMetadata()
                await provider.refresh(force: true)
            } else {
                _ = await CmuxTuiSurfaceProviderRegistry.shared.refresh(force: true)
            }
            guard self.cloudAccess.isCurrentUnavailableRetry(request) else { return }
            self.restoreCloudResource(
                resource,
                preferredURL: preferredURL,
                automaticRetriesRemaining: max(automaticRetriesRemaining - 1, 0)
            )
        }
        // The staged projection resolves on its own once the provider
        // publishes the resource, so a miss here is still loading. The
        // provider's settled port scan or the restore deadline ends it.
        cloudAccess.showRestoring(retry: recover, unavailableMessage: message)
        if automaticRetriesRemaining > 0 { cloudAccess.retryUnavailable() }
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
        cloudBrowserProxyAddress = nil
        websiteDataStore = preservesExplicitEphemeralWebsiteDataStore
            ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: identifier)
        // The route may still be connecting. Do not construct its WebView with
        // an unconfigured store: its first network session must own the proxy.
    }

    /// Apply proxy credentials before the first request, with no system-network fallback.
    func prepareCloudBrowserNavigation() {
        if cloudAccess.model?.route == .loopback {
            websiteDataStore.proxyConfigurations = []
            if webView.configuration.websiteDataStore !== websiteDataStore {
                replaceWebViewPreservingState(from: webView, websiteDataStore: websiteDataStore,
                                              reason: "ssh_loopback_route", restoreAfterReplacement: false)
            }
            return
        }
        guard let endpoint = cloudAccess.model?.browserProxy,
              let address = cloudAccess.model?.target.host else { return }
        guard endpoint != cloudBrowserProxyEndpoint || address != cloudBrowserProxyAddress else { return }
        cloudBrowserProxyEndpoint = endpoint
        cloudBrowserProxyAddress = address
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
