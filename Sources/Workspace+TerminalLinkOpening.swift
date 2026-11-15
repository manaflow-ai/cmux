import CmuxCloud
import CmuxCore
import CmuxPanes
import CmuxSurfaceCatalogModel
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    /// Resolve the connection from the terminal's authoritative owner, including native SSH projections.
    func remoteTerminalFilePreviewConfiguration(for surfaceID: UUID) -> WorkspaceRemoteConfiguration? {
        guard let configuration = remoteConfiguration, configuration.transport == .ssh else { return nil }
        if usesSSHTui {
            let expectedMachine = SurfaceMachineID(rawValue: SSHTuiConnection(configuration: configuration).id)
            guard machineOwningSurface(surfaceID) == expectedMachine else {
                return nil
            }
        } else if !isRemoteTerminalSurface(surfaceID) {
            return nil
        }
        return configuration
    }

    /// Where a remote file link's file is read from: the managed SSH connection,
    /// or the SSH host behind a mirrored `cmux ssh-tmux` session.
    func remoteTerminalFilePreviewRoute(for surfaceID: UUID) -> RemoteTerminalFilePreviewRoute? {
        if let configuration = remoteTerminalFilePreviewConfiguration(for: surfaceID) {
            return RemoteTerminalFilePreviewRoute(configuration: configuration)
        }
        return remoteTmuxFilePreviewRoute(for: surfaceID)
    }

    /// A mirrored tmux pane has no `remoteConfiguration`, so its files are read over
    /// the mirror's own ControlMaster. A click never opens a new connection or
    /// prompts for auth: without a live master the read fails closed.
    private func remoteTmuxFilePreviewRoute(for surfaceID: UUID) -> RemoteTerminalFilePreviewRoute? {
        guard let sessionMirror = remoteTmuxSessionMirror,
              !sessionMirror.connection.exited,
              case .pane = remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) else { return nil }
        let host = sessionMirror.host
        // A brokered or non-ssh route can't be reached by a plain ssh to the destination.
        guard host.transport == .ssh, host.transportBroker == nil else { return nil }
        return RemoteTerminalFilePreviewRoute(host: host)
    }

    /// The terminal behind a remote file link, including a pane owned by a tmux mirror.
    func remoteFilePreviewSourcePanel(for surfaceID: UUID) -> TerminalPanel? {
        terminalPanel(for: surfaceID) ?? remoteTmuxControlPane(surfaceID: surfaceID)?.pane.panel
    }

    /// A mirrored pane is focused when its window tab is focused and it is that window's active pane.
    func remoteFilePreviewSourceIsFocused(_ surfaceID: UUID) -> Bool {
        if focusedPanelId == surfaceID { return true }
        guard let location = remoteTmuxControlPane(surfaceID: surfaceID) else { return false }
        return focusedPanelId == location.containerPanelID && location.pane.isFocused
    }

    /// The workspace panel a preview opens next to. A mirrored pane isn't in the
    /// workspace's split tree, so the preview goes beside its window tab.
    func remoteFilePreviewAnchorPanelID(for surfaceID: UUID) -> UUID {
        remoteTmuxControlPane(surfaceID: surfaceID)?.containerPanelID ?? surfaceID
    }

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              terminalLinkIsRemoteTerminal(target.surfaceID),
              remoteConfiguration?.transport == .ssh
                || remoteTmuxFilePreviewRoute(for: target.surfaceID) != nil,
              let panel = remoteFilePreviewSourcePanel(for: target.surfaceID) else { return false }
        _ = panel.hostedView.openRemoteFilePreview(tokens: [rawValue])
        return true
    }

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              let resource = SurfaceCatalog.shared.resource(forPanel: target.surfaceID)
                ?? SurfaceCatalog.shared.resource(forPanel: target.containerPanelID),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool = true) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(inPane: targetPane, url: url, focus: focus) != nil
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url,
            focus: focus
        ) != nil
    }
}
