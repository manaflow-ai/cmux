import CmuxPanes
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

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId),
              let resource = SurfaceCatalog.shared.resource(forPanel: target.surfaceID),
              resource.machine.cloudMachineID != nil,
              VMTunnelManager(purpose: .browser).writtenConfig() != nil,
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let rewritten = CmuxTuiSurfaceProvider.privateBrowserURL(url.absoluteString, privateAddress: address),
              let privateURL = URL(string: rewritten) else { return nil }
        return CloudTerminalLinkTarget(url: privateURL)
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

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url
        ) != nil
    }
}
