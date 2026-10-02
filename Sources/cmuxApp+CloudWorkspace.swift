import CmuxCloud
import CmuxCloudMachines
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
        return CloudWorkspaceCoordinator(
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
            createWorkspace: { request in
                guard let manager = AppDelegate.shared?.tabManagerFor(windowId: request.windowID) else { return nil }
                let validate: @MainActor () throws -> Void = { [weak manager] in
                    try Task.checkCancellation()
                    guard CloudMachinesFeature.isEnabled, auth.accountFlow.isAuthenticated,
                          machinePinStore.scopeIdentifier == request.scopeID,
                          let manager, !manager.isFinalizedForWindowClose else { throw CancellationError() }
                }
                try validate()
                guard let provider = await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: request.machineID) else {
                    throw VMClientError.backendUnreachable(url: AuthEnvironment.apiBaseURL.absoluteString, detail: "Cloud machine provider unavailable")
                }
                try validate()
                let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: .cloud(request.machineID), provider: provider, catalog: SurfaceCatalog.shared,
                    name: nil, focus: false, host: .init(manager: manager),
                    validateOperation: validate
                )
                return result.opened?.workspaceID
            }
        )
    }
}
