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

    func openOrFocusTerminalBrowserFileLink(url: URL, sourcePanelId: UUID) -> Bool {
        let canonicalURL = BrowserLocalFileReadAccessPolicy.fileOnly
            .resolvedNavigationURL(for: url)
        guard let targetIdentity = BrowserLocalFileIdentity(url: canonicalURL) else { return false }
        if let existing = panels.values.compactMap({ $0 as? BrowserPanel }).first(where: {
            $0.localFileReadAccessPolicy == .fileOnly
                && $0.bypassesRemoteWorkspaceProxyForTabDuplication
                && $0.effectiveURLForTerminalFileReuse
                    .flatMap { BrowserLocalFileIdentity(url: $0) } == targetIdentity
        }), existing.reloadTerminalFileForReuse(canonicalURL) {
            focusPanel(existing.id)
            return true
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            return newBrowserSurface(
                inPane: targetPane,
                url: canonicalURL,
                focus: true,
                bypassRemoteProxy: true,
                localFileReadAccessPolicy: .fileOnly
            ) != nil
        }
        return newBrowserSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            url: canonicalURL,
            bypassRemoteProxy: true,
            localFileReadAccessPolicy: .fileOnly
        ) != nil
    }
}
