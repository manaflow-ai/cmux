import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation

/// Composes SSH carriers with the same terminal graph and native projections as Cloud.
@MainActor
final class SSHTuiWorkspaceCoordinator {
    private let catalog: SurfaceCatalog
    private let clientURL: () -> URL?
    private let paths: CloudTuiClientPaths
    private var attempts: [UUID: Task<Void, Never>] = [:]

    init(catalog: SurfaceCatalog, clientURL: @escaping () -> URL?, paths: CloudTuiClientPaths) {
        self.catalog = catalog
        self.clientURL = clientURL
        self.paths = paths
    }

    func connect(workspace: Workspace, configuration: WorkspaceRemoteConfiguration) {
        for projection in catalog.projections where projection.workspaceID == workspace.id && projection.resource.machine.isSSH {
            let provider = catalog.provider(for: projection.resource.machine) as? CmuxTuiSurfaceProvider
            _ = provider?.manualMirrorSessions[projection.panelID]?.retryConnection()
        }
        attempts.removeValue(forKey: workspace.id)?.cancel()
        let attemptID = UUID()
        workspace.sshTuiConnectionAttemptID = attemptID
        attempts[workspace.id] = Task { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            defer {
                if workspace.sshTuiConnectionAttemptID == attemptID { self.attempts[workspace.id] = nil }
            }
            do {
                try await self.attach(workspace: workspace, configuration: configuration, attemptID: attemptID, restoring: true)
            } catch is CancellationError {
            } catch {
                guard workspace.sshTuiConnectionAttemptID == attemptID else { return }
                workspace.applyRemoteConnectionStateUpdate(.error, detail: CloudMachineLink.errorText(error), target: configuration.displayTarget)
            }
        }
    }

    func provider(connection: SSHTuiConnection) throws -> CmuxTuiSurfaceProvider {
        let machine = SurfaceMachineID(rawValue: connection.id)
        if let existing = catalog.provider(for: machine) as? CmuxTuiSurfaceProvider { return existing }
        guard let clientURL = clientURL() else { throw CloudMachineLink.LinkError.clientMissing }
        let links = SSHTuiLinkManager(connection: connection, clientURL: clientURL, paths: paths,
                                     isEnabled: { ManagedRemoteConnectionsPolicy.isEnabled })
        let provider = CmuxTuiSurfaceProvider(summary: .ssh(connection), links: links, catalog: catalog)
        catalog.register(provider)
        return provider
    }

    func open(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, initialCommand: [String]? = nil) async throws {
        attempts.removeValue(forKey: workspace.id)?.cancel()
        let attemptID = UUID()
        workspace.sshTuiConnectionAttemptID = attemptID
        let restoring = workspace.remoteConfiguration != nil
        workspace.remoteConfiguration = configuration
        workspace.applyRemoteConnectionStateUpdate(.connecting, detail: nil, target: configuration.displayTarget)
        try await attach(workspace: workspace, configuration: configuration, attemptID: attemptID, initialCommand: initialCommand, restoring: restoring)
    }

    private func attach(workspace: Workspace, configuration: WorkspaceRemoteConfiguration, attemptID: UUID, initialCommand: [String]? = nil, restoring: Bool = false) async throws {
        let connection = SSHTuiConnection(configuration: configuration)
        let provider = try provider(connection: connection)
        let machine = provider.machine
        var reservation = reserveInitialTerminal(workspace: workspace, machine: machine, configuration: configuration)
        var completed = false
        defer {
            if !completed, workspace.sshTuiConnectionAttemptID == attemptID, let reservation {
                workspace.failReservedCloudTerminalPane(reservation, error: CloudDiagnosticFailure.network)
            }
        }
        if let saved = configuration.restoredSSHSession, saved.sshSessionOwner != "cmux-tui" {
            throw CloudDiagnosticFailure.unsupported
        }
        guard await provider.refreshCurrentGraph(force: false) else {
            throw CloudMachineLink.LinkError.spawnFailed(provider.info.linkError ?? CloudDiagnosticFailure.network.label)
        }
        try requireCurrent(workspace: workspace, attemptID: attemptID)
        if !configuration.preserveAfterTerminalExit {
            workspace.applyRemoteConnectionStateUpdate(.connected, detail: nil, target: configuration.displayTarget)
            completed = true
            return
        }
        let existing = catalog.projections.filter { $0.workspaceID == workspace.id && $0.resource.machine == machine }
        if !existing.isEmpty {
            provider.projectionsRestored()
        } else if let binding = workspace.cloudVMBinding,
                  binding.vmID == connection.id,
                  let remoteID = binding.remoteWorkspaceID {
            // A missing saved terminal is never permission to create another shell.
            let group = try catalog.remoteWorkspaceGroup(machine: machine, workspaceID: remoteID)
            for placement in group.placements {
                let result = try await catalog.project(placement.resource, into: .workspace(id: workspace.id, placement: .tab),
                                                       focus: false, adopting: reservation)
                try requireCurrent(workspace: workspace, attemptID: attemptID)
                if let pending = reservation {
                    workspace.completeReservedCloudTerminalPane(pending, adoptedPanelID: result.projection.panelID)
                    reservation = nil
                }
            }
        } else {
            let connected = try await provider.links.connected(machineID: connection.id)
            guard let link = await provider.links.link(machineID: connection.id) else { throw CancellationError() }
            let request = CloudTuiRequests.createWorkspaceArguments(
                socketPath: connected.socketPath, empty: true
            ).withIdempotencyKey("ssh-workspace-" + workspace.stableId.uuidString.lowercased())
            let response = try await link.run(arguments: request)
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let remoteID = CmuxTuiSnapshotParser.createdWorkspace(fromResult: object) else {
                throw CmuxTuiSurfaceProvider.ProviderError.invalidSnapshot(connection.id)
            }
            let resource = try await provider.createTerminal(
                command: initialCommand ?? connection.shellCommand, cwd: nil, name: nil, remoteWorkspaceID: remoteID,
                request: CloudTerminalCreationRequest(id: workspace.stableId, remoteWorkspaceID: remoteID, restoring: restoring)
            )
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: connection.id, isBase: false, remoteWorkspaceID: remoteID)
            let projected = try await catalog.project(resource.id, into: .workspace(id: workspace.id, placement: .tab),
                                                      focus: false, adopting: reservation)
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            if let reservation { workspace.completeReservedCloudTerminalPane(reservation, adoptedPanelID: projected.projection.panelID) }
        }
        completed = true
        workspace.applyRemoteConnectionStateUpdate(.connected, detail: nil, target: configuration.displayTarget)
    }

    /// Replace the local scaffold before yielding so an SSH workspace can never start a local shell.
    private func reserveInitialTerminal(workspace: Workspace, machine: SurfaceMachineID,
                                        configuration: WorkspaceRemoteConfiguration) -> CloudTerminalPaneReservation? {
        guard configuration.preserveAfterTerminalExit else { return nil }
        if let pending = workspace.cloudPendingCreations.values.first(where: { $0.machine == machine }) {
            workspace.restartReservedCloudTerminalPane(pending)
            return pending
        }
        guard workspace.cloudVMBinding == nil,
              !catalog.projections.contains(where: { $0.workspaceID == workspace.id && $0.resource.machine == machine }) else { return nil }
        let scaffold = Set(workspace.panels.keys)
        guard let reservation = workspace.reserveCloudTerminalPane(
            machine: machine, at: .workspace(id: workspace.id, placement: .tab), focus: false
        ) else { return nil }
        reservation.retry = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.connect(workspace: workspace, configuration: configuration)
        }
        for panelID in scaffold { SurfacePaneFactory.close(panelID: panelID, in: workspace.id) }
        return reservation
    }

    private func requireCurrent(workspace: Workspace, attemptID: UUID) throws {
        try Task.checkCancellation()
        guard workspace.sshTuiConnectionAttemptID == attemptID, !workspace.isRetiredFromOwningTabManager,
              ManagedRemoteConnectionsPolicy.isEnabled else { throw CancellationError() }
    }

    func disconnect(workspace: Workspace) {
        workspace.sshTuiConnectionAttemptID = nil
        attempts.removeValue(forKey: workspace.id)?.cancel()
        for projection in catalog.projections where projection.workspaceID == workspace.id && projection.resource.machine.isSSH {
            let provider = catalog.provider(for: projection.resource.machine) as? CmuxTuiSurfaceProvider
            _ = provider?.manualMirrorSessions[projection.panelID]?.cancelConnectionAttempt()
            if !ManagedRemoteConnectionsPolicy.isEnabled, let manager = provider?.links as? SSHTuiLinkManager {
                Task { await manager.disconnect() }
            }
        }
    }
}
