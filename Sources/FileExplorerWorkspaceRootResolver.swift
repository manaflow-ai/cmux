import CmuxAuthRuntime
import Foundation

/// Both Files presentations resolve through the same workspace and account authority.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    let catalog: SurfaceCatalog
    let teamScope: @MainActor @Sendable () -> AuthenticatedTeamScope?
    let cloudEnabled: @MainActor @Sendable () -> Bool
    let managedCloudEnabled: @MainActor @Sendable () -> Bool

    init(
        catalog: SurfaceCatalog = .shared,
        teamScope: @escaping @MainActor @Sendable () -> AuthenticatedTeamScope? = {
            AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope
        },
        cloudEnabled: @escaping @MainActor @Sendable () -> Bool = { CloudMachinesFeature.isEnabled },
        managedCloudEnabled: @escaping @MainActor @Sendable () -> Bool = { ManagedCloudPolicy.isEnabled }
    ) {
        self.catalog = catalog
        self.teamScope = teamScope
        self.cloudEnabled = cloudEnabled
        self.managedCloudEnabled = managedCloudEnabled
    }

    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        // A cmux-tui binding is the explicit Cloud filesystem authority. A
        // legacy managedCloudVMID on an SSH workspace must keep using its SSH
        // transport, otherwise Files would silently change hosts.
        if let binding = workspace.cloudVMBinding {
            let vmID = binding.vmID
            let managedEnabled = managedCloudEnabled()
            let featureEnabled = cloudEnabled()
            let identity = Self.cloudIdentity(
                workspace,
                vmID: vmID,
                managedPolicyEnabled: managedEnabled,
                featureEnabled: featureEnabled,
                catalog: catalog,
                teamScope: teamScope
            )
            let connected = catalog.machines[.cloud(vmID)]?.linkState == .connected
            let detail: String?
            if !managedEnabled {
                detail = ManagedCloudPolicy.disabledMessage
            } else if !featureEnabled {
                detail = CloudMachinesFeature.disabledMessage
            } else if !connected {
                detail = String(localized: "fileExplorer.status.cloudDisconnected", defaultValue: "Cloud machine is not connected")
            } else {
                detail = nil
            }
            let catalog = self.catalog
            let teamScope = self.teamScope
            let cloudEnabled = self.cloudEnabled
            let managedCloudEnabled = self.managedCloudEnabled
            let target = identity.map { identity in
                CloudFileExplorerTarget(identity: identity, isCurrent: { @MainActor [weak workspace] in
                    guard let workspace else { return false }
                    return Self.cloudIdentity(
                        workspace,
                        vmID: vmID,
                        managedPolicyEnabled: managedCloudEnabled(),
                        featureEnabled: cloudEnabled(),
                        catalog: catalog,
                        teamScope: teamScope
                    ) == identity
                })
            }
            return .remoteCloud(
                workspaceId: workspace.id, vmID: vmID,
                displayTarget: catalog.machines[.cloud(vmID)]?.name ?? vmID,
                rootPath: target == nil ? nil : workspace.trustedRemoteCurrentDirectory,
                isAvailable: target != nil,
                unavailableDetail: detail,
                target: target
            )
        }
        if workspace.usesRemoteDirectoryProvenance {
            // A projection without an unambiguous workspace owner never becomes local or SSH.
            if !workspace.cloudBindingState.projectedResources.isEmpty ||
                catalog.projectionRecords(forWorkspace: workspace.id).contains(where: { !$0.resource.machine.isLocal }) {
                return .remoteCloud(workspaceId: workspace.id, vmID: "", displayTarget: "",
                                    rootPath: nil, isAvailable: false, unavailableDetail: nil, target: nil)
            }
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else { return .none }
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(destination: configuration.destination,
                    port: configuration.port, identityFile: configuration.identityFile, sshOptions: configuration.sshOptions),
                displayTarget: configuration.displayTarget,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: workspace.remoteConnectionState == .connected,
                unavailableDetail: workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            )
        }
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? .none : .local(workspaceId: workspace.id, path: path)
    }

    private static func cloudIdentity(
        _ workspace: Workspace,
        vmID: String,
        managedPolicyEnabled: Bool,
        featureEnabled: Bool,
        catalog: SurfaceCatalog,
        teamScope: @MainActor @Sendable () -> AuthenticatedTeamScope?
    ) -> CloudFileExplorerTarget.Identity? {
        guard !workspace.isRetiredFromOwningTabManager, workspace.cloudVMBinding?.vmID == vmID,
              WorkspaceCloudVMBinding.normalizedVMID(vmID) != nil,
              managedPolicyEnabled, featureEnabled, let team = teamScope(),
              let provider = catalog.provider(for: .cloud(vmID)),
              catalog.machines[.cloud(vmID)]?.linkState == .connected,
              catalog.cloudStateObservations[.cloud(vmID)]?.freshness == .current else { return nil }
        if let concrete = provider as? CmuxTuiSurfaceProvider,
           concrete.isFeatureSuspended || concrete.fileAccessTeamScope != team { return nil }
        let projections = catalog.projectionRecords(forWorkspace: workspace.id)
        guard projections.allSatisfy({ $0.resource.machine.isLocal || $0.resource.machine == .cloud(vmID) }) else { return nil }
        guard workspace.cloudBindingState.projectedResources.values.allSatisfy({
            $0.machine.isLocal || $0.machine == .cloud(vmID)
        }) else { return nil }
        let remoteID = workspace.cloudVMBinding?.remoteWorkspaceID
        if let remoteID, catalog.cloudStates[.cloud(vmID)]?.workspaces.contains(where: { $0.id == remoteID }) != true {
            return nil
        }
        return CloudFileExplorerTarget.Identity(workspaceID: workspace.id, vmID: vmID,
            remoteWorkspaceID: remoteID, team: team, provider: ObjectIdentifier(provider),
            generation: catalog.cloudStates[.cloud(vmID)]?.cursor?.generation)
    }
}
