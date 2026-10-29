import CmuxCloud
import CmuxCloudMachines
import CmuxSurfaceCatalogModel
import Foundation

extension cmuxApp {
    /// Builds the one machine pin store, scoped to the signed-in user and the
    /// selected team so pins never leak across accounts.
    static func makeCloudMachinePinStore(auth: MacAuthComposition) -> CloudMachinePinStore {
        return CloudMachinePinStore(defaults: .standard, scopeProvider: { [auth] in
            guard let userID = auth.accountFlow.currentIdentity?.id, !userID.isEmpty else { return nil }
            return "user:\(userID)|team:\(auth.accountFlow.confirmedTeamID ?? "personal")"
        })
    }

    /// Builds the shared Cloud composition so the sidebar and shortcut use one order store.
    static func makeCloudWorkspaceComposition(
        auth: MacAuthComposition
    ) -> (machinePinStore: CloudMachinePinStore, workspaceCoordinator: CloudWorkspaceCoordinator) {
        let machinePinStore = makeCloudMachinePinStore(auth: auth)
        let workspaceCoordinator = makeCloudWorkspaceCoordinator(auth: auth, machinePinStore: machinePinStore)
        return (machinePinStore, workspaceCoordinator)
    }

    /// The fleet, in its reported order, minus every machine that cannot receive
    /// a new workspace: one being deleted, or one locked past its free-access
    /// window (the same rule the sidebar's New Workspace row uses). Lock state
    /// is computed exactly as the sidebar computes it for the machine's row.
    static func cloudWorkspaceTargetMachineIDs(
        page: VMListPage,
        deleting: Set<String>,
        now: Date = Date()
    ) -> [String] {
        let windowDays = page.limits?.freeAccessWindowDays ?? 0
        return page.vms.filter { summary in
            !deleting.contains(summary.id) && MachineSnapshotBuilder
                .snapshot(from: summary, freeAccessWindowDays: windowDays, now: now)
                .acceptsNewWorkspaces
        }.map(\.id)
    }

    /// Composes live authentication, sidebar ordering, and workspace projection.
    static func makeCloudWorkspaceCoordinator(
        auth: MacAuthComposition,
        machinePinStore: CloudMachinePinStore
    ) -> CloudWorkspaceCoordinator {
        return makeCloudWorkspaceCoordinator(
            machinePinStore: machinePinStore,
            allowsOperation: { CloudMachinesFeature.isEnabled && auth.accountFlow.isAuthenticated },
            loadMachines: {
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                // GET /api/vm returns the entire owned fleet; SurfaceCatalog may be cold
                // or contain only providers discovered by an earlier background pass.
                return cloudWorkspaceTargetMachineIDs(
                    page: try await client.listPage(),
                    deleting: MachineDeleteCoordinator.shared.hiddenMachineIDs
                )
            },
            tabManager: { AppDelegate.shared?.tabManagerFor(windowId: $0) },
            provider: { await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: $0) },
            catalog: SurfaceCatalog.shared
        )
    }

    /// Composes the native creation path with the window and provider owners.
    /// Keeping these boundaries injectable lets shortcut tests delay remote work
    /// while exercising the same local admission and focus policy as the app.
    static func makeCloudWorkspaceCoordinator(
        machinePinStore: CloudMachinePinStore,
        allowsOperation: @escaping @MainActor @Sendable () -> Bool,
        loadMachines: @escaping @MainActor @Sendable () async throws -> [String],
        tabManager: @escaping @MainActor (UUID) -> TabManager?,
        provider: @escaping @MainActor (String) async -> (any SurfaceProvider)?,
        catalog: SurfaceCatalog
    ) -> CloudWorkspaceCoordinator {
        CloudWorkspaceCoordinator(
            machinePinStore: machinePinStore,
            allowsOperation: allowsOperation,
            loadMachines: loadMachines,
            createWorkspace: { request in
                guard let manager = tabManager(request.windowID) else { return nil }
                let validate: @MainActor () throws -> Void = { [weak manager] in
                    try Task.checkCancellation()
                    guard allowsOperation(),
                          machinePinStore.scopeIdentifier == request.scopeID,
                          let manager, !manager.isFinalizedForWindowClose else { throw CancellationError() }
                }
                try validate()
                let host = CloudWorkspaceCreationHost(manager: manager)
                let focus = request.selectionRevision == manager.cloudWorkspaceSelection.revision
                let provisionalTitle = catalog.cloudWorkspaceCreationCoordinator
                    .provisionalWorkspaceTitle(
                        machine: .cloud(request.machineID), name: nil, catalog: catalog
                    )
                let reservation = try catalog.cloudWorkspaceCreationCoordinator.reserveLocalWorkspace(
                    machine: .cloud(request.machineID),
                    title: provisionalTitle,
                    focus: focus,
                    host: host,
                    validateOperation: validate
                )
                var handedToCreation = false
                defer {
                    if !handedToCreation,
                       !catalog.cloudWorkspaceCreationCoordinator.ownsReservation(reservation) {
                        host.discard(reservation, catalog: catalog)
                    }
                }
                guard let provider = await provider(request.machineID) else {
                    throw VMClientError.backendUnreachable(url: AuthEnvironment.apiBaseURL.absoluteString, detail: "Cloud machine provider unavailable")
                }
                try validate()
                let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: .cloud(request.machineID), provider: provider, catalog: catalog,
                    name: nil, focus: focus, existingReservation: reservation, host: host,
                    validateOperation: validate
                )
                handedToCreation = true
                return result.opened?.workspaceID
            }
        )
    }
}
