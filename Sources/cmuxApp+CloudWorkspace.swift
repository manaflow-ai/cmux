import CmuxCloudMachines
import Foundation

extension cmuxApp {
    /// Builds the one machine pin store, scoped to the signed-in user and the
    /// selected team so pins never leak across accounts.
    static func makeCloudMachinePinStore(auth: MacAuthComposition) -> CloudMachinePinStore {
        CloudMachinePinStore(defaults: .standard, scopeProvider: { [auth] in
            guard let userID = auth.accountFlow.currentIdentity?.id, !userID.isEmpty else { return nil }
            return "user:\(userID)|team:\(auth.accountFlow.confirmedTeamID ?? "personal")"
        })
    }

    /// Composes live authentication, authoritative fleet loading, and workspace projection.
    static func makeCloudWorkspaceCoordinator(auth: MacAuthComposition) -> CloudWorkspaceCoordinator {
        return CloudWorkspaceCoordinator(
            defaultMachineStore: DefaultCloudMachineStore(defaults: .standard),
            allowsOperation: { CloudMachinesFeature.isEnabled && auth.accountFlow.isAuthenticated },
            loadMachines: {
                guard let client = VMClient.shared else { throw VMClientError.notSignedIn }
                // GET /api/vm returns the entire owned fleet; SurfaceCatalog may be cold
                // or contain only providers discovered by an earlier background pass.
                let page = try await client.listPage()
                return page.vms.map { CloudMachineDescriptor(id: $0.id, isDesktop: $0.resolvedKind == .desktop) }
            },
            createWorkspace: { id, focus in
                let host = AppDelegate.shared?.preferredMainWindowContextForWorkspaceCreation(
                    debugSource: "cloud.workspace.create"
                ).map { CloudWorkspaceCreationHost(manager: $0.tabManager) }
                let accountID = auth.accountFlow.currentIdentity?.id
                let teamID = auth.accountFlow.confirmedTeamID
                guard let provider = await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: id) else {
                    throw VMClientError.backendUnreachable(url: AuthEnvironment.apiBaseURL.absoluteString, detail: "Cloud machine provider unavailable")
                }
                try Task.checkCancellation()
                guard CloudMachinesFeature.isEnabled, auth.accountFlow.isAuthenticated,
                      accountID == auth.accountFlow.currentIdentity?.id,
                      teamID == auth.accountFlow.confirmedTeamID else { return nil }
                let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: .cloud(id), provider: provider, catalog: SurfaceCatalog.shared,
                    name: nil, focus: focus, host: host
                )
                return result.opened?.workspaceID
            }
        )
    }
}
