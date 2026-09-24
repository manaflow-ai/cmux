import CmuxCore
import Foundation

extension Workspace {
    /// All managed SSH entrypoints converge here, including saved workspace descriptors.
    func configureSSHTuiConnection(_ configuration: WorkspaceRemoteConfiguration, autoConnect: Bool) -> Bool {
        AppDelegate.shared?.sshTuiWorkspaceCoordinator.disconnect(workspace: self)
        remoteSessionController?.stop()
        remoteSessionController = nil
        activeRemoteSessionControllerID = nil
        remoteConfiguration = configuration
        remoteProxyEndpoint = nil
        remoteDaemonStatus = WorkspaceRemoteDaemonStatus()
        applyRemoteConnectionStateUpdate(autoConnect ? .connecting : .disconnected, detail: nil, target: configuration.displayTarget)
        if autoConnect { AppDelegate.shared?.sshTuiWorkspaceCoordinator.connect(workspace: self, configuration: configuration) }
        return true
    }

    /// Replaces the remote workload while retaining the native pane and its retry identity.
    func respawnSSHTuiSurface(
        panelID: UUID, command: String?, workingDirectory: String?, tmuxStartCommand: String?,
        focus: Bool?, allowTextBoxFocusDefault: Bool
    ) -> TerminalPanel? {
        let catalog = SurfaceCatalog.shared
        guard cloudPendingCreations[panelID] == nil,
              let source = cloudTerminalSourcePlacement(forPanel: panelID), source.machine.isSSH,
              let original = source.resource, original.kind == .terminal,
              terminalPanel(for: panelID) != nil, let remoteWorkspaceID = source.remoteWorkspaceID,
              let configuration = remoteConfiguration,
              SSHTuiConnection(configuration: configuration).id == source.machine.rawValue,
              let provider = catalog.provider(for: source.machine),
              let paneID = paneId(forPanelId: panelID) else { return nil }
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command != nil, trimmed?.isEmpty != false { return nil }
        let connection = SSHTuiConnection(configuration: configuration)
        let argv = trimmed.map(connection.commandArguments) ?? connection.shellCommand
        let attemptID = sshTuiConnectionAttemptID
        let placement = CloudTerminalSourcePlacement(machine: source.machine, remoteWorkspaceID: remoteWorkspaceID)
        let reservation = CloudTerminalPaneReservation(workspaceID: id, panelID: panelID,
            machine: source.machine, sourcePlacement: placement)
        let replacement = catalog.withProjectionEndReason(for: [panelID], reason: .replaced) {
            catalog.endProjections(panelID: panelID, reason: .replaced)
            return respawnTerminalSurface(panelId: panelID, command: command,
                workingDirectory: nil, tmuxStartCommand: tmuxStartCommand, focus: focus,
                allowTextBoxFocusDefault: allowTextBoxFocusDefault, nativeReservation: reservation)
        }
        guard let replacement, cloudPendingCreations[panelID] === reservation else { return nil }
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        let request = CloudTerminalCreationRequest(id: requestID, remoteWorkspaceID: remoteWorkspaceID)
        var retiredOriginal = false
        var mutationToken: UUID?
        runOptimisticCloudTerminalCreation(
            reservation: reservation, requestID: requestID,
            destination: .tab(workspaceID: id, paneID: paneID.id.uuidString, index: nil),
            create: { [weak self] in
                guard let self, self.cloudPendingCreations[panelID] === reservation,
                      self.sshTuiConnectionAttemptID == attemptID,
                      self.remoteConfiguration.map({ SSHTuiConnection(configuration: $0).id }) == connection.id,
                      catalog.provider(for: source.machine) === provider else { throw CancellationError() }
                if !retiredOriginal {
                    do { try await provider.closeTerminal(original.id) }
                    catch { guard CmuxTuiSurfaceProvider.isSelectorNotFound(error) else { throw error } }
                    retiredOriginal = true
                }
                try Task.checkCancellation()
                guard self.cloudPendingCreations[panelID] === reservation,
                      self.sshTuiConnectionAttemptID == attemptID,
                      self.remoteConfiguration.map({ SSHTuiConnection(configuration: $0).id }) == connection.id,
                      catalog.provider(for: source.machine) === provider else { throw CancellationError() }
                return try await provider.createTerminal(command: argv, cwd: workingDirectory, name: nil,
                    remoteWorkspaceID: remoteWorkspaceID, request: request)
            },
            onStart: {
                if mutationToken == nil {
                    mutationToken = catalog.cloudWorkspaceProjectionCoordinator.beginLocalMutation(on: source.machine)
                }
            },
            onFinish: {
                if let token = mutationToken {
                    mutationToken = nil
                    catalog.cloudWorkspaceProjectionCoordinator.endLocalMutation(token, on: source.machine, catalog: catalog)
                }
            }
        )
        return replacement
    }

    var usesSSHTui: Bool {
        remoteConfiguration.map { $0.transport == .ssh && $0.terminalTransport == .ssh && !$0.skipDaemonBootstrap } ?? false
    }

    /// Resolves both Cloud and SSH projections through their registered provider.
    func tuiMirrorSession(for surfaceID: UUID) -> CloudTuiManualMirrorSession? {
        guard let projection = SurfaceCatalog.shared.projectionIncludingPendingRestore(forPanel: surfaceID),
              let provider = SurfaceCatalog.shared.provider(for: projection.resource.machine) as? CmuxTuiSurfaceProvider else { return nil }
        return provider.manualMirrorSessions[surfaceID]
    }
}
