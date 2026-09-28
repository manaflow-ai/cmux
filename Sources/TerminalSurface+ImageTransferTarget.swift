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

    /// The TTY to check for a user-started SSH session, or nil when the
    /// transfer is local without any process lookup.
    ///
    /// Every drop and paste calls this on the main actor, and a nil result
    /// inserts the path in the same turn, as upstream Ghostty does. Keep it
    /// O(foreground job): the PTY names its foreground group (`tcgetpgrp`),
    /// and only a group with an `ssh` or `et` member needs the bounded async
    /// lookup. Never add a scan of all processes here; on a loaded Mac that
    /// delayed every dropped path by seconds.
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
        // Without a live PTY there is no foreground group to read; keep the
        // async lookup so an unknown job is never assumed local.
        if let processGroupID = foregroundProcessID(),
           !TerminalSSHSessionDetector.foregroundJobHasRemoteShell(
               processGroupID: Int32(processGroupID),
               ttyName: ttyName
           ) {
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
