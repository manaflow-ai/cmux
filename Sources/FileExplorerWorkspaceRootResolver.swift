import CmuxCloud
import CmuxAuthRuntime
import CmuxSurfaceCatalogModel
import Foundation

/// Both Files presentations resolve through the same workspace and account authority.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    let catalog: SurfaceCatalog
    let teamScope: @MainActor @Sendable () -> AuthenticatedTeamScope?
    let cloudEnabled: @MainActor @Sendable () -> Bool
    let managedCloudEnabled: @MainActor @Sendable () -> Bool

    init(
        catalog: SurfaceCatalog? = nil,
        teamScope: @escaping @MainActor @Sendable () -> AuthenticatedTeamScope? = {
            AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope
        },
        cloudEnabled: @escaping @MainActor @Sendable () -> Bool = { CloudMachinesFeature.isEnabled },
        managedCloudEnabled: @escaping @MainActor @Sendable () -> Bool = { ManagedCloudPolicy.isEnabled }
    ) {
        self.catalog = catalog ?? SurfaceCatalog.shared
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
            if vmID.hasPrefix("ssh:") {
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
            // The binding's machine id is authoritative.  Device ids use the
            // same wire representation as cloud ids but are owned by the
            // device provider, so do not force them through `.cloud`.
            let machine = SurfaceMachineID(rawValue: vmID)
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
            let connected = catalog.machines[machine]?.linkState == .connected
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
                displayTarget: catalog.machines[machine]?.name ?? vmID,
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
        // A plain `ssh user@host` typed into a local terminal (not a `cmux ssh`
        // workspace): root the explorer at the remote host's filesystem while the
        // session is active. The workspace title (`user@host:cwd`) is the only
        // remote-cwd signal (Ghostty rejects remote OSC 7 pwd reports); when the
        // session exits the local shell resets the title, which re-triggers
        // resolution and reverts the explorer to the local root.
        if let sshSession = workspace.focusedPanelId.flatMap({ panelId in
            workspace.candidateTTYNames(forPanel: panelId).lazy
                .compactMap { TerminalSSHSessionDetector.detect(forTTY: $0) }
                .first
        }) {
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(
                    destination: sshSession.destination,
                    port: sshSession.port,
                    identityFile: sshSession.identityFile,
                    sshOptions: sshSession.sshOptions
                ),
                displayTarget: sshSession.destination,
                rootPath: TerminalSSHSessionDetector.remoteWorkingDirectory(fromTitle: workspace.title),
                isAvailable: true,
                unavailableDetail: nil
            )
        }
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        // A local workspace may not have reported a cwd yet (fresh and
        // restored workspaces do this briefly).  Files still belongs to this
        // Mac; use its home directory instead of dropping the root entirely.
        let localPath = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : path
        return .local(workspaceId: workspace.id, path: localPath)
    }

    private static func cloudIdentity(
        _ workspace: Workspace,
        vmID: String,
        managedPolicyEnabled: Bool,
        featureEnabled: Bool,
        catalog: SurfaceCatalog,
        teamScope: @MainActor @Sendable () -> AuthenticatedTeamScope?
    ) -> CloudFileExplorerTarget.Identity? {
        let machine = SurfaceMachineID(rawValue: vmID)
        guard !workspace.isRetiredFromOwningTabManager, workspace.cloudVMBinding?.vmID == vmID,
              WorkspaceCloudVMBinding.normalizedVMID(vmID) != nil,
              managedPolicyEnabled, featureEnabled, let team = teamScope(),
              let provider = catalog.provider(for: machine),
              catalog.machines[machine]?.linkState == .connected,
              catalog.cloudStateObservations[machine]?.freshness == .current else { return nil }
        if let concrete = provider as? CmuxTuiSurfaceProvider,
           concrete.isFeatureSuspended || concrete.fileAccessTeamScope != team || !concrete.capabilities.exec { return nil }
        guard catalog.projectionMachines(forWorkspace: workspace.id).allSatisfy({
            $0.isLocal || $0 == machine
        }) else { return nil }
        guard workspace.cloudBindingState.projectedResources.values.allSatisfy({
            $0.machine.isLocal || $0.machine == machine
        }) else { return nil }
        let remoteID = workspace.cloudVMBinding?.remoteWorkspaceID
        if let remoteID, catalog.cloudStates[machine]?.workspaces.contains(where: { $0.id == remoteID }) != true {
            return nil
        }
        return CloudFileExplorerTarget.Identity(workspaceID: workspace.id, vmID: vmID,
            remoteWorkspaceID: remoteID, team: team, provider: ObjectIdentifier(provider))
    }
}
