import CmuxCloudMachines
import Foundation

extension cmuxApp {
    /// Composes live authentication, authoritative fleet loading, and workspace projection.
    static func makeCloudWorkspaceCoordinator(auth: MacAuthComposition) -> CloudWorkspaceCoordinator {
        CloudWorkspaceCoordinator(
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
                guard let provider = await CmuxTuiSurfaceProviderRegistry.shared.providerRefreshingIfMissing(machineID: id) else {
                    throw VMClientError.backendUnreachable(url: AuthEnvironment.apiBaseURL.absoluteString, detail: "Cloud machine provider unavailable")
                }
                try Task.checkCancellation()
                guard CloudMachinesFeature.isEnabled, auth.accountFlow.isAuthenticated else { return nil }
                let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                    machine: .cloud(id), provider: provider, catalog: SurfaceCatalog.shared,
                    name: nil, focus: focus
                )
                return result.opened?.workspaceID
            }
        )
    }
}
