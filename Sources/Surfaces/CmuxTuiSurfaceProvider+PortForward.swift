import Foundation

extension CmuxTuiSurfaceProvider {
    /// Rebind active browser panes when the VM private address changes.
    func refreshCloudBrowserRoutes() {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID) else { continue }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    if let url = URL(string: raw) { configureBrowser(browser, url: url, resourceID: resource.id) }
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
    func configureBrowser(_ browser: BrowserPanel, url: URL, resourceID: SurfaceResourceID? = nil) {
        let requestedPort = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        let fallbackID: SurfaceResourceID = if info.hasDesktop, (CmuxTuiSnapshotParser.desktopPort...6916).contains(requestedPort) {
            SurfaceResourceID(machine: machine, kind: .display, key: "display:\(requestedPort - 6900)")
        } else {
            SurfaceResourceID(machine: machine, kind: .browser, key: "port:\(requestedPort)")
        }
        let resourceID = resourceID ?? browser.cloudAccess.resourceID
            ?? catalog.projectionRecord(forPanel: browser.id).flatMap { $0.resource.machine.isLocal ? nil : $0.resource }
            ?? fallbackID
        guard resourceID.machine == machine,
              browser.cloudAccess.resourceID?.machine == nil || browser.cloudAccess.resourceID?.machine == machine,
              (try? catalog.validateOwnership(of: [resourceID], at: .workspace(id: browser.workspaceId, placement: .tab))) != nil else {
            browser.cloudAccess.showUnavailable(SurfaceTransferRejection.cloudMachineMismatch.message)
            return
        }
        guard let address = info.privateAddress,
              let privateURL = CloudPortRoutePlan.privateURL(url.absoluteString, address: address) else {
            browser.cloudAccess.showUnavailable(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            return
        }
        // Check the VM origin before rewriting it to localhost. Otherwise the
        // implicit localhost allowance could bypass a private-origin deny rule.
        guard browserPolicy().allowsTrustedInternalURL(privateURL) else {
            browser.cloudAccess.showUnavailable(String(localized: "browser.error.urlAllowlist.userMessage", defaultValue: "This URL is not allowed by the embedded-browser URL policy."))
            return
        }
        let port = privateURL.port ?? (privateURL.scheme?.lowercased() == "https" ? 443 : 80)
        browser.webView.stopLoading()
        let model = accessModel(port: port, address: address, scheme: privateURL.scheme ?? "http")
        browser.retainTransferredSurfaceMachine(machine)
        browser.cloudAccess.configure(model: model, url: privateURL, resourceID: resourceID)
        browser.prepareCloudBrowserStore(machineID: machineID)
        browser.showCloudAddress(privateURL)
        model.connect()
        browser.cloudAccess.routeDidConfigure()
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
                    let endpoint = try await self.links.browserProxy(machineID: self.machineID)
                    if self.providerID == "freestyle", port == CmuxTuiSnapshotParser.desktopPort,
                       try await !CloudBrowserRouting.desktopIsReachable(endpoint: endpoint, address: address, port: port) {
                        try Task.checkCancellation()
                        guard self.isCurrentLifecycleGeneration(generation), self.isRegisteredInCatalog() else { throw CancellationError() }
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                        _ = try await client.openPort(id: self.machineID, port: port)
                    }
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
                    configureBrowser(browser, url: url, resourceID: resource.id)
                    materializedPanels.insert(projection.panelID)
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
}
