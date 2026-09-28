import CmuxTerminal
import Foundation

extension TerminalSurface {
    @MainActor
    func resolvedImageTransferTarget(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> TerminalImageTransferTarget {
        // The bound session remains authoritative even during reconnect, before
        // its local workspace or a fresh remote numeric surface can be resolved.
        let workspace = workspace ?? owningWorkspace()
        // Native SSH projections use SCP/SFTP upload for both paste and drag/drop.
        // They have no Cloud image coordinator, so never turn an SSH file into
        // a local path or a Cloud image request.
        if let workspace, workspace.usesSSHTui,
           workspace.machineOwningSurface(id)?.isSSH == true {
            return .remote(.workspaceRemote)
        }
        if mode == .paste, isManagedCloudImageTarget(in: workspace) { return .cloud }
        guard let workspace else { return .local }
        if workspace.isRemoteTerminalSurface(id) {
            return .remote(.workspaceRemote)
        }
        // Manual tmux mirrors have no local TTY for the SSH process detector.
        if let target = AppDelegate.shared?.remoteTmuxController.remoteUploadTarget(forSurfaceId: id) {
            return .remote(target)
        }
        return .local
    }

    @MainActor
    func resolvedImageTransferTargetAsync(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil,
        detector: @escaping @Sendable (String) -> DetectedSSHSession? = { tty in
            TerminalSSHSessionDetector.detect(forTTY: tty)
        },
        timeoutSleep: @escaping @Sendable (TimeInterval) async -> Void = {
            timeout in
            await TerminalSSHSessionDetector
                .defaultDetectionTimeoutSleep(timeout)
        }
    ) async -> TerminalImageTransferTarget {
        let workspace = workspace ?? owningWorkspace()
        let knownTarget = resolvedImageTransferTarget(mode: mode, in: workspace)
        guard let ttyName = imageTransferDetectionTTY(mode: mode, in: workspace),
              let session = await TerminalSSHSessionDetector.detectAsync(
                  forTTY: ttyName,
                  detector: detector,
                  timeoutSleep: timeoutSleep
              ) else {
            return knownTarget
        }
        return .remote(.detectedSSH(session))
    }

    @MainActor
    func imageTransferDetectionTTY(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> String? {
        let workspace = workspace ?? owningWorkspace()
        guard resolvedImageTransferTarget(mode: mode, in: workspace) == .local,
              let ttyName = workspace?.surfaceTTYNames[id],
              !ttyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return ttyName
    }

    @MainActor
    private func isManagedCloudImageTarget(in workspace: Workspace?) -> Bool {
        if hostedView.cloudTerminalOverlay.session != nil { return true }
        guard let workspace else { return false }
        if workspace.cloudProjectedResource(forPanel: id)?.id.machine.cloudMachineID != nil { return true }
        if (workspace.panels[id] as? TerminalPanel)?.cloudAttachment != nil { return true }
        // A VM label alone also describes legacy SSH workspaces. Their existing
        // SSH upload path remains authoritative until a native Cloud view exists.
        return false
    }
}
