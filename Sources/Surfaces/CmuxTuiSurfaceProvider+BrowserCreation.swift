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
            try validateTerminalMutationLifecycle(lifecycle)
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
            guard self.isRegisteredInCatalog() else {
                // The daemon mutation is committed even if the local provider was
                // retired while waiting. Close its tab before discarding the receipt
                // so a reconnect cannot strand an unowned browser.
                _ = try? await link.run(arguments: CloudTuiRequests.closeTabArguments(
                    socketPath: connected.socketPath,
                    tabID: created.tabID
                ))
                throw CancellationError()
            }
            // A reconnect can advance the generation while keeping this provider
            // registered. The active provider adopts the committed receipt so the
            // browser remains discoverable after reconnect.
            return self.recordCreatedBrowser(
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
