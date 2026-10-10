import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    /// Creates a browser in cmux-tui so the browser's page, network, and localhost
    /// context belong to this machine rather than to the Mac running cmux.
    func createBrowser(
        url: URL,
        name: String?,
        remoteWorkspaceID: String?,
        screenID: String?,
        paneID: String?,
        idempotencyKey: String?,
        correlationKey: String?
    ) async throws -> SurfaceResource {
        let lifecycle = lifecycleGeneration
        try validateTerminalMutationLifecycle(lifecycle)
        return try await terminalMutationQueue.run {
            try self.validateTerminalMutationLifecycle(lifecycle)
            let connected = try await self.links.connected(machineID: self.machineID)
            try self.validateTerminalMutationLifecycle(lifecycle)
            guard let link = await self.links.link(machineID: self.machineID) else {
                throw ProviderError.machineAsleep(self.machineID)
            }
            let data = try await link.run(arguments: CloudTuiRequests.createBrowserArguments(
                socketPath: connected.socketPath,
                workspaceID: remoteWorkspaceID,
                screenID: screenID,
                paneID: paneID,
                url: url.absoluteString,
                name: name,
                idempotencyKey: idempotencyKey,
                correlationKey: correlationKey
            ))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let created = CmuxTuiSnapshotParser.createdBrowser(fromCreateResult: object) else {
                throw ProviderError.browserNotCreated
            }
            // The daemon mutation is committed even if this provider was replaced
            // while the request was in flight. Adopt the receipt into the provider
            // currently registered for the machine so the browser remains owned and
            // discoverable after reconnect. If access ended entirely, surface an
            // explicit state failure instead of cancelling after creating a blank
            // local pane (or silently compensating the remote tab away).
            guard let activeProvider = self.catalog.provider(for: self.machine) as? CmuxTuiSurfaceProvider,
                  activeProvider.isRegisteredInCatalog() else {
                throw ProviderError.stateUnavailable(self.machineID)
            }
            return activeProvider.recordCreatedBrowser(
                created,
                workspaceID: created.workspaceID,
                url: url,
                name: name
            )
        }
    }

    func recordCreatedBrowser(
        _ created: CmuxTuiSnapshotParser.CreatedBrowserPath,
        workspaceID: String,
        url: URL,
        name: String?
    ) -> SurfaceResource {
        let remoteWorkspace = cloudState?.workspaces.first(where: { $0.id == workspaceID }).map {
            SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
        } ?? info.remoteWorkspaces?.first(where: { $0.id == workspaceID })
            ?? SurfaceRemoteWorkspace(
                id: workspaceID,
                name: workspaceID,
                index: info.remoteWorkspaces?.count ?? 0,
                focused: false
            )
        var resource = SurfaceResource(
            id: SurfaceResourceID(machine: machine, kind: .browser, key: created.browserID),
            title: name ?? url.absoluteString,
            detail: url.absoluteString,
            lifecycle: .launching,
            agent: nil,
            remoteWorkspace: remoteWorkspace,
            port: CmuxTuiSnapshotParser.localhostPort(fromURL: url.absoluteString),
            url: url.absoluteString
        )
        resource.remoteViews = [SurfaceRemoteView(
            tabID: created.tabID,
            workspace: remoteWorkspace,
            screenID: created.screenID,
            paneID: created.paneID,
            name: name,
            focused: true
        )]
        pendingRemoteCreations[resource.id] = PendingRemoteCreation(
            resource: resource,
            receipt: created.cursor,
            tabID: created.tabID
        )
        catalog.upsert(resource, from: self)
        publishPendingMutationMetadata()
        scheduleRefresh()
        return resource
    }
}
