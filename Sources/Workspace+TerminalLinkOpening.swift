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

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool {
        guard remoteConfiguration?.transport == .ssh,
              let target = surfaceOwnershipTarget(for: sourcePanelId),
              terminalLinkIsRemoteTerminal(target.surfaceID),
              let panel = terminalPanel(for: target.surfaceID) else { return false }
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
        if isRemoteTmuxMirror {
            // In a mirror a link opens as a sibling tab, never a new split
            // pane. It lands in the pane holding the clicked terminal's own
            // tab (`target.containerPanelID`, not `sourcePanelId`, which may be
            // a tmux pane inside that window) rather than `focusedPaneId` —
            // those diverge once the side-by-side browser pane exists.
            guard let paneId = paneId(forPanelId: target.containerPanelID)
                ?? bonsplitController.focusedPaneId
                ?? bonsplitController.allPaneIds.first else {
                return false
            }
            return newBrowserSurface(inPane: paneId, url: url, focus: focus) != nil
        }
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
