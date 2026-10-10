import CmuxCloudTui
import CmuxSurfaceCatalogModel
import Foundation

@MainActor
extension CmuxTuiSurfaceProvider {
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    private nonisolated static func performRemoteBrowserCreation(
        link: CloudMachineLink,
        request: CloudTuiRequest
    ) async throws -> CmuxTuiSnapshotParser.CreatedBrowserPath? {
        let data = try await link.run(arguments: request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return CmuxTuiSnapshotParser.createdBrowser(fromCreateResult: object)
    }

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
        return try await terminalMutationQueue.runCommitted {
            try self.validateTerminalMutationLifecycle(lifecycle)
            let connected = try await self.links.connected(machineID: self.machineID)
            try self.validateTerminalMutationLifecycle(lifecycle)
            guard let link = await self.links.link(machineID: self.machineID) else {
                throw ProviderError.machineAsleep(self.machineID)
            }
            let request = CloudTuiRequests.createBrowserArguments(
                socketPath: connected.socketPath,
                workspaceID: remoteWorkspaceID,
                screenID: screenID,
                paneID: paneID,
                url: url.absoluteString,
                name: name,
                idempotencyKey: idempotencyKey,
                correlationKey: correlationKey
            )
            // Keep the transport and response parsing off the main actor. The
            // committed queue still serializes the mutation and the receipt is
            // adopted below on the provider's actor-isolated state.
            guard let created = try await Self.performRemoteBrowserCreation(link: link, request: request) else {
                throw ProviderError.browserNotCreated
            }
            do {
                return try self.recordCommittedBrowser(
                    created, url: url, name: name, expectedLifecycle: lifecycle
                )
            } catch {
                // A committed daemon tab must not be orphaned when this
                // provider has no eligible replacement to adopt it.
                let cleanup = Task { @MainActor in
                    try? await self.closeRemoteTab(id: created.tabID, inRemoteWorkspace: created.workspaceID)
                }
                _ = await cleanup.result
                throw error
            }
        }
    }

    /// Keeps a committed receipt across replacement in the same ownership scope.
    func recordCommittedBrowser(
        _ created: CmuxTuiSnapshotParser.CreatedBrowserPath,
        url: URL,
        name: String?,
        expectedLifecycle: UInt64? = nil
    ) throws -> SurfaceResource {
        // Account or machine teardown is not a reconnect. The previous provider
        // may already be suspended; only a live replacement for this machine and
        // team may adopt its committed receipt.
        guard let activeProvider = catalog.provider(for: machine) as? CmuxTuiSurfaceProvider,
              activeProvider.isRegisteredInCatalog(), !activeProvider.hasLostAccess,
              !activeProvider.isFeatureSuspended,
              activeProvider.ownerTeamID == ownerTeamID,
              activeProvider !== self || expectedLifecycle == nil || activeProvider.lifecycleGeneration == expectedLifecycle else {
            throw ProviderError.stateUnavailable(machineID)
        }
        return activeProvider.recordCreatedBrowser(
            created,
            workspaceID: created.workspaceID,
            url: url,
            name: name
        )
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
