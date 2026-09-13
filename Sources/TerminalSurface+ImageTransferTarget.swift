import CmuxTerminal

extension TerminalSurface {
    @MainActor
    func resolvedImageTransferTarget(mode: TerminalImageTransferMode = .paste) -> TerminalImageTransferTarget {
        // The bound session remains authoritative even during reconnect, before
        // its local workspace or a fresh remote numeric surface can be resolved.
        if mode == .paste, isManagedCloudImageTarget { return .cloud }
        guard let workspace = owningWorkspace() else { return .local }
        if workspace.isRemoteTerminalSurface(id) {
            return .remote(.workspaceRemote)
        }
        // Manual tmux mirrors have no local TTY for the SSH process detector.
        if let target = AppDelegate.shared?.remoteTmuxController.remoteUploadTarget(forSurfaceId: id) {
            return .remote(target)
        }
        if let ttyName = workspace.surfaceTTYNames[id],
           let session = TerminalSSHSessionDetector.detect(forTTY: ttyName) {
            return .remote(.detectedSSH(session))
        }
        return .local
    }

    @MainActor
    private var isManagedCloudImageTarget: Bool {
        if hostedView.cloudTerminalOverlay.session != nil { return true }
        guard let workspace = owningWorkspace() else { return false }
        if workspace.cloudProjectedResource(forPanel: id)?.id.machine.cloudMachineID != nil { return true }
        if (workspace.panels[id] as? TerminalPanel)?.cloudAttachment != nil { return true }
        return workspace.cloudVMID != nil && workspace.isRemoteTerminalSurface(id)
    }
}
