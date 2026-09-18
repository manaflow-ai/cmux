import CmuxPanes
import CmuxSettings
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

    func openTerminalBrowserLink(
        url: URL,
        sourcePanelId: UUID,
        placement: TerminalLinkBrowserPlacement,
        focus: Bool = true
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        return BrowserSplitContainer.workspace(self).openBrowser(
            of: target.containerPanelID,
            placement: placement,
            request: BrowserSplitRequest(url: url, focus: focus, preloadInBackground: false)
        ) != nil
    }
}
