import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Rebind active browser panes when the VM private address changes.
    func refreshCloudBrowserRoutes() {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID) else { continue }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    if let url = URL(string: raw) {
                        let configured = configureBrowser(browser, url: browser.cloudRestoreURL(on: url), resourceID: resource.id)
                        if configured { browser.pendingCloudRestoreURL = nil }
                    }
                case .unsupported(let message):
                    browser.cloudAccess.showUnavailable(message)
                }
            }
        }
    }

    /// Create the browser with native connection state before attempting access.
    /// The authenticated userspace proxy keeps each VM's address and port.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool,
        reusing existingPane: (workspaceID: UUID, panelID: UUID)? = nil
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        try Task.checkCancellation()
        try catalog.validateOwnership(of: [resource.id], at: destination)
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let pane = try existingPane ?? SurfacePaneFactory.makeBrowserPane(url: nil, at: destination, focus: focus)
        guard let browser = SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID) else {
            throw ProviderError.localForwardURLUnavailable
        }
        switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let raw):
            guard let url = URL(string: raw) else { throw ProviderError.localForwardURLUnavailable }
            configureBrowser(browser, url: url, resourceID: resource.id)
        case .unsupported(let message):
            browser.cloudAccess.showUnavailable(message)
        }
        return pane
    }

    /// Bind the page to its machine proxy without activating a system VPN.
    @discardableResult
    func configureBrowser(_ browser: BrowserPanel, url: URL, resourceID: SurfaceResourceID? = nil,
                          preserveCurrentNavigation: Bool = false) -> Bool {
        let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let fallbackID: SurfaceResourceID = if info.hasDesktop, (CmuxTuiSnapshotParser.desktopPort...6916).contains(requestedPort) {
            SurfaceResourceID(machine: machine, kind: .display, key: "display:\(requestedPort - 6900)")
        } else {
            SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(requestedPort)")
        }
        let projectedResource = catalog.projectionRecord(forPanel: browser.id).flatMap {
            $0.resource.machine.isLocal ? nil : $0.resource
        }
        let retainedResource = browser.cloudAccess.resourceID ?? projectedResource
        let explicitResource: SurfaceResourceID?
        if let resourceID {
            explicitResource = resourceID
        } else if let retainedResource,
                  Self.port(for: retainedResource, catalog: catalog) == nil
                    || Self.port(for: retainedResource, catalog: catalog) == requestedPort {
            explicitResource = retainedResource
        } else {
            // A URL that changes the service port must resolve to the requested
            // catalog slot instead of carrying the old display identity forward.
            explicitResource = nil
        }
        if let explicitResource,
           let expectedPort = Self.port(for: explicitResource, catalog: catalog),
           expectedPort != requestedPort {
            browser.cloudAccess.showUnavailable(CloudGuestDisplaySnapshot.unavailableMessage)
            return false
        }
        if explicitResource == nil, fallbackID.kind == .display,
           fallbackID.key != SurfaceResourceID.desktopDisplayKey,
           catalog.resources[fallbackID] == nil {
            browser.cloudAccess.showUnavailable(CloudGuestDisplaySnapshot.unavailableMessage)
            return false
        }
        let resourceID = explicitResource ?? fallbackID
        let isGlobalDock = DockSplitStore.liveStore(containingPanel: browser.id)?.scope == .global
        let destinationOwned = isGlobalDock
            || (try? catalog.validateOwnership(of: [resourceID], at: .workspace(id: browser.workspaceId, placement: .tab))) != nil
        guard resourceID.machine == machine,
              browser.cloudAccess.resourceID?.machine == nil || browser.cloudAccess.resourceID?.machine == machine,
              destinationOwned else {
            browser.cloudAccess.showUnavailable(SurfaceTransferRejection.cloudMachineMismatch.message)
            return false
        }
        guard let address = info.privateAddress,
              let privateURL = CloudPortRoutePolicy().privateURL(url.absoluteString, address: address, allowLoopback: machine.isSSH) else {
            browser.cloudAccess.showUnavailable(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            return false
        }
        // Check the VM origin before rewriting it to localhost. Otherwise the
        // implicit localhost allowance could bypass a private-origin deny rule.
        guard browserPolicy().allowsTrustedInternalURL(privateURL) else {
            browser.cloudAccess.showUnavailable(String(localized: "browser.error.urlAllowlist.userMessage", defaultValue: "This URL is not allowed by the embedded-browser URL policy."))
            return false
        }
        if let existing = catalog.projectionRecord(forPanel: browser.id), existing.resource != resourceID {
            catalog.endProjections(panelID: browser.id, reason: .replaced)
            catalog.restore([SurfaceProjectionRecord(panelID: browser.id, resource: resourceID)], workspaceID: browser.workspaceId)
        }
        let port = privateURL.port ?? (privateURL.scheme?.lowercased() == "https" ? 443 : 80)
        let model = accessModel(port: port, address: address, scheme: privateURL.scheme ?? "http")
        browser.retainTransferredSurfaceMachine(machine)
        if preserveCurrentNavigation {
            browser.prepareCloudBrowserStore(machineID: machineID)
            browser.bindCloudBrowserNavigation()
            browser.cloudAccess.adoptCommittedRoute(model: model, url: privateURL, resourceID: resourceID)
            model.connect()
        } else {
            browser.configureCloudBrowser(model: model, url: privateURL, resourceID: resourceID)
        }
        materializedPanels.insert(browser.id)
        return true
    }

    private static func port(for resource: SurfaceResourceID, catalog: SurfaceCatalog) -> Int? {
        if let port = catalog.resources[resource]?.port { return port }
        if resource.kind == .display,
           let number = Int(resource.key.split(separator: ":").last ?? ""), (1...16).contains(number) {
            return 6900 + number
        }
        if resource.kind == .browser, resource.key.hasPrefix("port:"),
           let port = Int(resource.key.dropFirst("port:".count)) {
            return port
        }
        return nil
    }

    func accessModel(port: Int, address: String, scheme: String = "http") -> CloudPortAccessModel {
        let target = CloudPortForwardTarget(host: address, port: port)
        return portAccessStore.model(machineID: machineID, target: target, scheme: scheme) {
            CloudPortAccessModel(
                target: target,
                coordinator: portAccessStore.coordinator,
                wake: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw CancellationError() }
                    let generation = self.currentLifecycleGeneration
                    // Sleeping machines need the control plane to wake. An awake
                    // desktop is checked through the existing browser carrier below.
                    if !self.isAwake {
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                        _ = try await client.openPort(id: self.machineID, port: target.port)
                    }
                    guard self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog() else { throw CancellationError() }
                },
                startForward: { [weak self] target in
                    guard let self, let portForwards = self.portForwards, self.isRegisteredInCatalog() else { throw ProviderError.hubUnavailable }
                    var target = target
                    target.fallbackHosts = await self.links.privateAddresses(for: self.machineID)
                    let forward = try await portForwards.forward(machineID: self.machineID, to: target)
                    do {
                        try await forward.warmUpHub()
                        try Task.checkCancellation()
                        return await forward.localPort
                    } catch {
                        await portForwards.close(machineID: self.machineID, port: target.port)
                        throw error
                    }
                },
                stopForward: { [portForwards, machineID] in
                    await portForwards?.close(machineID: machineID, port: port)
                },
                startBrowserProxy: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw ProviderError.hubUnavailable }
                    let generation = self.currentLifecycleGeneration
#if DEBUG
                    let desktopStartedAt = Date()
                    cmuxDebugLog("cloud.desktop.proxy.begin machine=\(self.machineID) port=\(port)")
#endif
                    let endpoint = try await self.links.browserProxy(machineID: self.machineID)
#if DEBUG
                    cmuxDebugLog("cloud.desktop.proxy.endpoint machine=\(self.machineID) port=\(port) elapsedMs=\(Int(Date().timeIntervalSince(desktopStartedAt) * 1000))")
#endif
                    if self.providerID == "freestyle", port == CmuxTuiSnapshotParser.desktopPort,
                       try await !CloudBrowserRouting.desktopIsReachable(endpoint: endpoint, address: address, port: port) {
                        try Task.checkCancellation()
                        guard self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog() else { throw CancellationError() }
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
#if DEBUG
                        cmuxDebugLog("cloud.desktop.proxy.heal.begin machine=\(self.machineID) port=\(port)")
#endif
                        _ = try await client.openPort(id: self.machineID, port: port)
#if DEBUG
                        cmuxDebugLog("cloud.desktop.proxy.heal.complete machine=\(self.machineID) port=\(port) elapsedMs=\(Int(Date().timeIntervalSince(desktopStartedAt) * 1000))")
#endif
                    }
#if DEBUG
                    cmuxDebugLog("cloud.desktop.proxy.ready machine=\(self.machineID) port=\(port) elapsedMs=\(Int(Date().timeIntervalSince(desktopStartedAt) * 1000))")
#endif
                    guard self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog() else { throw CancellationError() }
                    return endpoint
                }
            )
        }
    }

    func reprojectRestoredBrowserPanes(generation: UInt64) {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) where !materializedPanels.contains(projection.panelID) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID),
                      isCurrentLifecycleGeneration(generation), catalog.canRestoreProjection(projection) else { continue }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    guard let url = URL(string: raw) else { continue }
                    let configured = configureBrowser(
                        browser,
                        url: browser.cloudRestoreURL(on: url),
                        resourceID: resource.id
                    )
                    if configured {
                        browser.pendingCloudRestoreURL = nil
                        materializedPanels.insert(projection.panelID)
                    }
                case .unsupported:
                    // Keep the placeholder eligible for a later explicit display
                    // discovery; its target may be supplied by the guest catalog.
                    continue
                }
            }
        }
    }

    /// Copying a link is read-only and always returns the private address.
    func portLinkURL(port: Int) async throws -> String {
        let resource = CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port)
        switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let url): return url
        case .unsupported(let message): throw SurfaceCatalogError.unsupported(message)
        }
    }

    /// Inspect an explicit forward without creating one.
    func localPortURL(port: Int) async throws -> String? {
        guard let localPort = await portForwards?.localPort(machineID: machineID, port: port) else { return nil }
        return "http://127.0.0.1:\(localPort)"
    }

    /// Explicit provider preview API retained for diagnostic callers only.
    func controlPlanePreviewURL(port: Int) async throws -> URL {
        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
        let endpoint = try await client.openPort(id: machineID, port: port)
        guard let url = URL(string: endpoint.openUrl), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ProviderError.invalidPreviewURL }
        return url
    }

    /// Show a retryable failure page owned by this provider and pane.
    private func showFailure(
        resource: SurfaceResource,
        label: String,
        error: any Error,
        pane: (workspaceID: UUID, panelID: UUID)
    ) {
        let text = CloudMachineLink.errorText(error)
        releaseRetryToken(panelID: pane.panelID)
        let port = resource.id.forwardedPort ?? resource.port
        let proxyAvailable = resource.kind == .browser && port != nil && machine.cloudMachineID != nil
        let token = SurfaceBrowserPlaceholderBridge.shared.register { [weak self] action in
            self?.handlePlaceholderAction(action, resource: resource, label: label, pane: pane)
        }
        browserPaneRetryTokens[pane.panelID] = token
        SurfacePaneFactory.showPlaceholder(
            SurfaceBrowserPlaceholder.failed(
                label,
                error: text,
                token: token,
                proxyAvailable: proxyAvailable
            ),
            panelID: pane.panelID,
            in: pane.workspaceID
        )
        #if DEBUG
        cmuxDebugLog("cloud.provider.endpointFailed label=\(label) error=\(String(reflecting: error))")
        #endif
    }

    private func handlePlaceholderAction(
        _ action: SurfaceBrowserPlaceholderAction,
        resource: SurfaceResource,
        label: String,
        pane: (workspaceID: UUID, panelID: UUID)
    ) {
        guard let paneID = SurfacePaneFactory.paneID(ofPanel: pane.panelID, in: pane.workspaceID) else { return }
        switch action {
        case .retry:
            browserPaneTasks[pane.panelID]?.cancel()
            browserPaneTasks[pane.panelID] = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    _ = try await self.materializeBrowserPane(
                        resource,
                        at: .tab(workspaceID: pane.workspaceID, paneID: paneID, index: nil),
                        focus: false,
                        reusing: pane
                    )
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showFailure(resource: resource, label: label, error: error, pane: pane)
                }
            }
        case .openProxy:
            guard let vmID = machine.cloudMachineID,
                  let port = resource.id.forwardedPort ?? resource.port else { return }
            browserPaneTasks[pane.panelID]?.cancel()
            browserPaneTasks[pane.panelID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.browserPaneTasks[pane.panelID] = nil }
                do {
                    let url = try await CloudPortProxy.url(vmID: vmID, port: port)
                    SurfacePaneFactory.showPlaceholder(
                        SurfaceBrowserPlaceholder.connecting(url.host ?? label),
                        panelID: pane.panelID,
                        in: pane.workspaceID
                    )
                    self.releaseRetryToken(panelID: pane.panelID)
                    _ = try await CloudPortProxy.open(url, replacing: pane)
                } catch {
                    guard !Task.isCancelled else { return }
                    self.showFailure(resource: resource, label: label, error: error, pane: pane)
                }
            }
        }
    }

    func releaseRetryToken(panelID: UUID) {
        if let token = browserPaneRetryTokens.removeValue(forKey: panelID) {
            SurfaceBrowserPlaceholderBridge.shared.unregister(token)
        }
    }
}
