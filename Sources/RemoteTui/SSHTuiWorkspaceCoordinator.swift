import CmuxCloud
import CmuxCloudTui
import CmuxCore
import CmuxSurfaceCatalogModel
import Foundation
import os

private let sshTuiWorkspaceLogger = Logger(subsystem: "com.cmuxterm.app", category: "SSHTuiWorkspace")

/// Composes SSH carriers with the same terminal graph and native projections as Cloud.
@MainActor
final class SSHTuiWorkspaceCoordinator {
    private let catalog: SurfaceCatalog
    private let clientURL: () -> URL?
    private let paths: CloudTuiClientPaths
    private var attempts: [UUID: Task<Void, Never>] = [:]
    private let agentStatus: SSHTuiAgentStatusProjector

    init(catalog: SurfaceCatalog, clientURL: @escaping () -> URL?, paths: CloudTuiClientPaths) {
        self.catalog = catalog
        self.clientURL = clientURL
        self.paths = paths
        agentStatus = SSHTuiAgentStatusProjector(catalog: catalog)
    }

    static func configurationForAttach(_ input: WorkspaceRemoteConfiguration) -> WorkspaceRemoteConfiguration {
        var configuration = input
        if let saved = configuration.restoredSSHSession,
           saved.sshSessionOwner != "cmux-tui",
           saved.legacyTmuxSSHConfiguration(agentSocketPath: configuration.agentSocketPath) == nil {
            configuration.restoredSSHSession = nil
        }
        return configuration
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
                                     isEnabled: { ManagedRemoteConnectionsPolicy.isEnabled },
                                     agentHookProviders: { SSHTuiConnection.agentHookProviders(defaults: .standard) })
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
        let preparedConfiguration = Self.configurationForAttach(configuration)
        if preparedConfiguration.restoredSSHSession == nil, configuration.restoredSSHSession != nil {
            // A workspace saved by the retired cmuxd-remote path can still be
            // opened as a normal cmux-tui SSH workspace. Do not turn that stale
            // descriptor into an "unsupported" Cloud error; it describes a
            // PTY that no longer has a supported owner, so start a fresh
            // daemon-owned workspace and keep the SSH destination/configuration.
            workspace.remoteConfiguration = preparedConfiguration
        }
        let configuration = preparedConfiguration
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
            // Use the same eligibility check as snapshot conversion, including
            // the legacy default when terminalTransport was not persisted.
            guard saved.legacyTmuxSSHConfiguration(agentSocketPath: configuration.agentSocketPath) != nil else {
                throw CloudDiagnosticFailure.unsupported
            }
        }
        guard await provider.refreshCurrentGraph(force: false) else {
            throw CloudMachineLink.LinkError.failureMessage(provider.info.linkFailureMessage)
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
            let request = Self.remoteWorkspaceCreationRequest(for: workspace, socketPath: connected.socketPath)
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
            if let title = Self.remoteWorkspaceTitleToPublish(for: workspace) {
                // A failed publish degrades to the daemon default name; log it rather than fail the attach.
                catalog.enqueueRemoteWorkspaceRename(on: machine, id: remoteID, name: title) { error in
                    sshTuiWorkspaceLogger.error("publishing the workspace title to \(remoteID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
            }
            workspace.cloudVMBinding = WorkspaceCloudVMBinding(vmID: connection.id, isBase: false, remoteWorkspaceID: remoteID)
            let projected = try await catalog.project(resource.id, into: .workspace(id: workspace.id, placement: .tab),
                                                      focus: false, adopting: reservation)
            try requireCurrent(workspace: workspace, attemptID: attemptID)
            if let reservation { workspace.completeReservedCloudTerminalPane(reservation, adoptedPanelID: projected.projection.panelID) }
        }
        completed = true
        workspace.applyRemoteConnectionStateUpdate(.connected, detail: nil, target: configuration.displayTarget)
    }

    /// The `workspace.create` request an SSH attach sends when the workspace has no remote identity yet.
    ///
    /// It stays unnamed so its creation fingerprint is stable: the idempotency
    /// key is per workspace, and the daemon rejects a replay whose parameters
    /// changed (`creation.conflict`), which a title edit between retries would cause.
    static func remoteWorkspaceCreationRequest(for workspace: Workspace, socketPath: String) -> CloudTuiRequest {
        CloudTuiRequests.createWorkspaceArguments(socketPath: socketPath, empty: true)
            .withIdempotencyKey("ssh-workspace-" + workspace.stableId.uuidString.lowercased())
    }

    /// The local title an SSH attach publishes to the remote workspace it just created.
    ///
    /// Once the workspace is bound, the daemon graph owns its name and
    /// reconciliation projects that name onto the local title, so a title from
    /// `--name` or a restored snapshot must reach the daemon first. Attach
    /// enqueues it as a rename before binding; the pending rename keeps
    /// reconciliation from painting the daemon default (`workspace-N`) meanwhile.
    /// Auto titles are derived locally and are not pinned into the daemon, and a
    /// title over the daemon's 1024-byte workspace-name limit is not sent.
    static func remoteWorkspaceTitleToPublish(for workspace: Workspace) -> String? {
        guard workspace.effectiveCustomTitleSource != .auto,
              let title = workspace.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty, title.utf8.count <= 1024 else { return nil }
        return title
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
