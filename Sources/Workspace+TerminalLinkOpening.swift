import CmuxBrowser
import CmuxPanes
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkContainsPanel(_ sourcePanelId: UUID) -> Bool {
        surfaceOwnershipTarget(for: sourcePanelId) != nil
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

    func terminalLinkSnapshotTerminalPanel(for sourcePanelId: UUID) -> TerminalPanel? {
        guard !terminalLinkIsRemoteTerminal(sourcePanelId) else { return nil }
        return controlTerminalPanel(for: sourcePanelId)
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        resolvedFileURL: URL?,
        fallback: @escaping @MainActor @Sendable () -> Void,
        completion: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            resolvedFileURL: resolvedFileURL,
            fallback: fallback,
            completion: completion
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

    func openOrFocusTerminalBrowserFileLink(resolvedURL: URL, sourcePanelId: UUID) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        return TerminalHTMLFileBrowserAction.openOrFocusResolvedFile(
            resolvedURL,
            browserPanels: panels.values.compactMap { $0 as? BrowserPanel },
            focusExisting: { focusPanel($0.id) },
            createBrowser: {
                if let targetPane = preferredRightSideTargetPane(
                    fromPanelId: target.containerPanelID
                ) {
                    return newBrowserSurface(
                        inPane: targetPane,
                        focus: true,
                        bypassRemoteProxy: true,
                        localFileReadAccessPolicy: .fileOnly
                    )
                }
                return newBrowserSplit(
                    from: target.containerPanelID,
                    orientation: .horizontal,
                    bypassRemoteProxy: true,
                    localFileReadAccessPolicy: .fileOnly
                )
            }
        )
    }
}
