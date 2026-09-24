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
