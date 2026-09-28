import CmuxTerminal

/// Where an image or file transfer goes, split so the one slow step is explicit.
enum TerminalImageTransferTargetResolution: Equatable {
    case resolved(TerminalImageTransferTarget)
    /// Only a process-table read of this TTY can tell a local shell from a
    /// user-started SSH session. That read can take seconds on a loaded Mac.
    case detectSSHSession(ttyName: String)

    static func target(detectedOn ttyName: String) -> TerminalImageTransferTarget {
        TerminalSSHSessionDetector.detect(forTTY: ttyName).map { .remote(.detectedSSH($0)) } ?? .local
    }
}

extension TerminalSurface {
    @MainActor
    func imageTransferTargetResolution(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> TerminalImageTransferTargetResolution {
        // The bound session remains authoritative even during reconnect, before
        // its local workspace or a fresh remote numeric surface can be resolved.
        let workspace = workspace ?? owningWorkspace()
        // Native SSH projections use SCP/SFTP upload for both paste and drag/drop.
        // They have no Cloud image coordinator, so never turn an SSH file into
        // a local path or a Cloud image request.
        if let workspace, workspace.usesSSHTui,
           workspace.machineOwningSurface(id)?.isSSH == true {
            return .resolved(.remote(.workspaceRemote))
        }
        if mode == .paste, isManagedCloudImageTarget(in: workspace) { return .resolved(.cloud) }
        guard let workspace else { return .resolved(.local) }
        if workspace.isRemoteTerminalSurface(id) {
            return .resolved(.remote(.workspaceRemote))
        }
        // Manual tmux mirrors have no local TTY for the SSH process detector.
        if let target = AppDelegate.shared?.remoteTmuxController.remoteUploadTarget(forSurfaceId: id) {
            return .resolved(.remote(target))
        }
        if let ttyName = workspace.surfaceTTYNames[id] {
            return .detectSSHSession(ttyName: ttyName)
        }
        return .resolved(.local)
    }

    /// Blocks on the process-table read when one is needed. Prefer
    /// ``resolveImageTransferTarget(mode:in:)`` from asynchronous callers.
    @MainActor
    func resolvedImageTransferTarget(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) -> TerminalImageTransferTarget {
        switch imageTransferTargetResolution(mode: mode, in: workspace) {
        case .resolved(let target):
            return target
        case .detectSSHSession(let ttyName):
            return TerminalImageTransferTargetResolution.target(detectedOn: ttyName)
        }
    }

    @MainActor
    func resolveImageTransferTarget(
        mode: TerminalImageTransferMode = .paste,
        in workspace: Workspace? = nil
    ) async -> TerminalImageTransferTarget {
        switch imageTransferTargetResolution(mode: mode, in: workspace) {
        case .resolved(let target):
            return target
        case .detectSSHSession(let ttyName):
            return await Task.detached(priority: .userInitiated) {
                TerminalImageTransferTargetResolution.target(detectedOn: ttyName)
            }.value
        }
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
