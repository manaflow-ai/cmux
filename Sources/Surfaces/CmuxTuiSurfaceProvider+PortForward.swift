import Foundation

/// The Ports and Desktop rows' panes: every route goes through
/// ``CloudPortRoutePlan``, and a machine with a private address is reached
/// over the user-space WireGuard hub on a loopback forward. Nothing here asks
/// for the Network Extension.
extension CmuxTuiSurfaceProvider {
    /// Creates the browser pane for a port or desktop row at once (showing the
    /// connecting placeholder) and navigates it when its route is ready. The
    /// forward exists before this returns, so `localPortURL(port:)` answers
    /// immediately afterwards.
    func materializeBrowserPane(
        _ resource: SurfaceResource,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> (workspaceID: UUID, panelID: UUID) {
        let generation = currentLifecycleGeneration
        try Task.checkCancellation()
        let desktop = resource.kind == .display
        let plan = CloudPortRoutePlan.plan(
            resource: resource,
            privateAddress: info.privateAddress,
            supportsControlPlanePreviews: capabilities.ports
        )
        switch plan {
        case .unsupported(let reason):
            throw SurfaceCatalogError.unsupported(reason)
        case .hubForward(let target, let remoteURL):
            let forward = try await hubForward(to: target)
            guard let localURL = CloudPortRoutePlan.localURL(rewriting: remoteURL, toLoopbackPort: await forward.localPort) else {
                throw ProviderError.localForwardURLUnavailable
            }
            try Task.checkCancellation()
            guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { throw CancellationError() }
            let label = Self.paneLabel(machineID: machineID, port: target.port, desktop: desktop)
            let pane = try Self.makeConnectingPane(label: label, at: destination, focus: focus)
            let machineWasAwake = isAwake
            // A provider that is stopped or replaced while this runs must not
            // touch the pane its successor now owns.
            browserPaneTasks[pane.panelID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.browserPaneTasks[pane.panelID] = nil }
                do {
                    try Task.checkCancellation()
                    if !machineWasAwake {
                        // Waking a paused machine is an explicit management
                        // operation. The returned public URL is ignored; the
                        // pane keeps the private route.
                        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
                        _ = try await client.openPort(id: self.machineID, port: target.port)
                    }
                    try Task.checkCancellation()
                    // Start the hub now so a hub that cannot come up is explained
                    // in the pane instead of surfacing as a browser error page.
                    try await forward.warmUpHub()
                    try Task.checkCancellation()
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: localURL)
                } catch {
                    guard !Task.isCancelled else { return }
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    Self.showFailure(label: label, error: error, pane: pane)
                }
            }
            return pane
        case .controlPlanePreview(let port):
            guard isRegisteredInCatalog() else { throw CancellationError() }
            let label = Self.paneLabel(machineID: machineID, port: port, desktop: desktop)
            let pane = try Self.makeConnectingPane(label: label, at: destination, focus: focus)
            browserPaneTasks[pane.panelID] = Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.browserPaneTasks[pane.panelID] = nil }
                do {
                    try Task.checkCancellation()
                    let url = try await self.controlPlanePreviewURL(port: port)
                    try Task.checkCancellation()
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    SurfacePaneFactory.navigate(panelID: pane.panelID, in: pane.workspaceID, to: url)
                } catch {
                    guard !Task.isCancelled else { return }
                    guard self.isCurrentLifecycleGeneration(generation) else { return }
                    Self.showFailure(label: label, error: error, pane: pane)
                }
            }
            return pane
        }
    }

    /// The link `port` opens as, shared by the pane, Copy Link, and
    /// `vm.port_open`: the loopback forward when the machine has a private
    /// address, else the control plane's tokened preview URL. Throws when the
    /// machine supports neither route or the route it has cannot be made;
    /// never falls back to an address only `cmux vpn up` can reach.
    func portLinkURL(port: Int) async throws -> String {
        if let local = try await localPortURL(port: port) { return local }
        return try await controlPlanePreviewURL(port: port).absoluteString
    }

    /// The control plane's tokened preview URL for `port`, the route for a
    /// machine without a private address. Only a web URL may reach a pane or
    /// the pasteboard, so anything else is refused here for every caller.
    func controlPlanePreviewURL(port: Int) async throws -> URL {
        guard let client = VMClient.shared else { throw ProviderError.notSignedIn }
        let endpoint = try await client.openPort(id: machineID, port: port)
        guard let url = URL(string: endpoint.openUrl),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw ProviderError.invalidPreviewURL }
        return url
    }

    /// The loopback URL that reaches `port` on this machine from any app on
    /// this Mac, starting the forward if needed. Nil when the machine has no
    /// private address, so its ports are only reachable through the control
    /// plane's preview URL; throws only when a forward should exist and could
    /// not be made.
    func localPortURL(port: Int) async throws -> String? {
        let plan = CloudPortRoutePlan.plan(
            resource: CmuxTuiSnapshotParser.portBrowser(machine: machine, port: port),
            privateAddress: info.privateAddress,
            supportsControlPlanePreviews: capabilities.ports
        )
        switch plan {
        case .hubForward(let target, _):
            return try await hubForward(to: target).localURLString
        case .controlPlanePreview:
            return nil
        case .unsupported(let reason):
            throw SurfaceCatalogError.unsupported(reason)
        }
    }

    private func hubForward(to target: CloudPortForwardTarget) async throws -> CloudLoopbackPortForward {
        guard let portForwards else { throw ProviderError.hubUnavailable }
        return try await portForwards.forward(machineID: machineID, to: target)
    }

    private static func makeConnectingPane(
        label: String,
        at destination: SurfaceDestination,
        focus: Bool
    ) throws -> (workspaceID: UUID, panelID: UUID) {
        let pane = try SurfacePaneFactory.makeBrowserPane(url: SurfacePaneFactory.blankURL, at: destination, focus: focus)
        SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.connecting(label), panelID: pane.panelID, in: pane.workspaceID)
        return pane
    }

    private static func showFailure(label: String, error: any Error, pane: (workspaceID: UUID, panelID: UUID)) {
        let text = CloudMachineLink.errorText(error)
        SurfacePaneFactory.showPlaceholder(SurfaceBrowserPlaceholder.failed(label, error: text), panelID: pane.panelID, in: pane.workspaceID)
        #if DEBUG
        cmuxDebugLog("cloud.provider.endpointFailed label=\(label) error=\(String(reflecting: error))")
        #endif
    }
}
