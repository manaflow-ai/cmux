import CmuxFoundation
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Rebind active browser panes when the VM private address changes.
    func refreshCloudBrowserRoutes() {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID) else { continue }
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    if let url = URL(string: raw) { configureBrowser(browser, url: url) }
                case .unsupported(let message):
                    browser.cloudAccess.showUnavailable(message)
                }
            }
        }
    }

    /// Create the browser with native connection state before attempting access.
    /// The user chooses forwarding explicitly in that pane.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool,
        reusing existingPane: (workspaceID: UUID, panelID: UUID)? = nil
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        try Task.checkCancellation()
        guard isRegisteredInCatalog() else { throw CancellationError() }
        let pane = try existingPane ?? SurfacePaneFactory.makeBrowserPane(url: SurfacePaneFactory.blankURL, at: destination, focus: focus)
        guard let browser = SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID) else {
            throw ProviderError.localForwardURLUnavailable
        }
        switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
        case .privateDirect(let raw):
            guard let url = URL(string: raw) else { throw ProviderError.localForwardURLUnavailable }
            configureBrowser(browser, url: url)
        case .unsupported(let message):
            browser.cloudAccess.showUnavailable(message)
        }
        return pane
    }

    func configureBrowser(_ browser: BrowserPanel, url: URL) {
        guard let address = info.privateAddress,
              let privateURL = CloudPortRoutePlan.privateURL(url.absoluteString, address: address) else {
            browser.cloudAccess.showUnavailable(String(localized: "cloud.portAccess.invalidURL", defaultValue: "This port does not have a valid HTTP or HTTPS address."))
            return
        }
        let port = privateURL.port ?? (privateURL.scheme == "https" ? 443 : 80)
        browser.webView.stopLoading()
        browser.cloudAccess.configure(model: accessModel(port: port, address: address), url: privateURL)
        browser.showCloudAddress(privateURL)
    }

    func accessModel(port: Int, address: String) -> CloudPortAccessModel {
        let target = CloudPortForwardTarget(host: address, port: port)
        return portAccessStore.model(machineID: machineID, target: target) {
            CloudPortAccessModel(
                machineID: machineID,
                target: target,
                coordinator: portAccessStore.coordinator,
                wake: { [weak self] in
                    guard let self, self.isRegisteredInCatalog() else { throw CancellationError() }
                    let generation = self.currentLifecycleGeneration
                    if !self.isAwake {
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                        _ = try await client.openPort(id: self.machineID, port: port)
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
                        await portForwards.close(machineID: self.machineID, port: port)
                        throw error
                    }
                },
                stopForward: { [portForwards, machineID] in
                    await portForwards?.close(machineID: machineID, port: port)
                }
            )
        }
    }

    func reprojectRestoredBrowserPanes(generation: UInt64) {
        for resource in catalog.snapshot.resources(on: machine) where resource.kind != .terminal {
            for projection in catalog.projections(of: resource.id) where !materializedPanels.contains(projection.panelID) {
                guard let browser = SurfacePaneFactory.browserPanel(panelID: projection.panelID, in: projection.workspaceID),
                      isCurrentLifecycleGeneration(generation) else { continue }
                materializedPanels.insert(projection.panelID)
                switch CloudPortRoutePlan.plan(resource: resource, privateAddress: info.privateAddress) {
                case .privateDirect(let raw):
                    if let url = URL(string: raw) { configureBrowser(browser, url: url) }
                case .unsupported(let message): browser.cloudAccess.showUnavailable(message)
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

    /// The noVNC URL uses only the VM private address. The private network is
    /// the access check, so no public preview token or endpoint is required.
    nonisolated static func privateDesktopURL(privateAddress: String) -> String {
        let base = CmuxInternalHostnames.directPortURL(
            privateAddress: privateAddress,
            port: CmuxTuiSnapshotParser.desktopPort
        )
        return "\(base)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }

    /// Turn a VM-local browser URL into the same URL on the VM private address.
    /// Path, query, fragment, scheme, and port stay unchanged.
    nonisolated static func privateBrowserURL(_ raw: String, privateAddress: String) -> String? {
        guard let parts = URLComponents(string: raw),
              let host = parts.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              ["localhost", "127.0.0.1", "0.0.0.0", "::1"].contains(host) else { return nil }
        return CloudPortRoutePlan.privateURL(raw, address: privateAddress)?.absoluteString
    }

    /// Shared Cloud terminal-link conversion for Workspace and Dock containers.
    nonisolated static func cloudTerminalLinkTarget(url: URL, resource: SurfaceResource, privateAddress: String) -> CloudTerminalLinkTarget? {
        guard resource.kind == .terminal, resource.machine.cloudMachineID != nil,
              let rewritten = privateBrowserURL(url.absoluteString, privateAddress: privateAddress),
              let privateURL = URL(string: rewritten) else { return nil }
        return CloudTerminalLinkTarget(url: privateURL)
    }

    /// Add the local URL used when this resource is projected on the Mac.
    nonisolated static func withPrivateBrowserURL(
        _ resource: SurfaceResource,
        privateAddress: String
    ) -> SurfaceResource {
        var updated = resource
        switch resource.kind {
        case .display:
            updated.url = privateDesktopURL(privateAddress: privateAddress)
        case .browser:
            if resource.id.key.hasPrefix("port:"), let port = resource.port {
                updated.url = CmuxInternalHostnames.directPortURL(
                    privateAddress: privateAddress,
                    port: port
                )
            } else if let raw = resource.url {
                updated.url = privateBrowserURL(raw, privateAddress: privateAddress)
            }
        case .terminal:
            break
        }
        return updated
    }

}
