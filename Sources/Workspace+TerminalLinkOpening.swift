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

    func openOrFocusTerminalBrowserFileLink(resolvedURL: URL, sourcePanelId: UUID) -> Bool {
        guard let targetIdentity = BrowserLocalFileIdentity(resolvedURL: resolvedURL) else { return false }
        if let existing = panels.values.compactMap({ $0 as? BrowserPanel }).first(where: {
            $0.canReuseTerminalFile(resolvedURL, identity: targetIdentity)
        }), existing.reloadTerminalFileForReuse(resolvedURL, identity: targetIdentity) {
            focusPanel(existing.id)
            return true
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            guard let browser = newBrowserSurface(
                inPane: targetPane,
                url: resolvedURL,
                focus: true,
                bypassRemoteProxy: true,
                localFileReadAccessPolicy: .fileOnly
            ) else {
                return false
            }
            browser.rememberTerminalFileForReuse(resolvedURL, identity: targetIdentity)
            return true
        }
        guard let browser = newBrowserSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            url: resolvedURL,
            bypassRemoteProxy: true,
            localFileReadAccessPolicy: .fileOnly
        ) else {
            return false
        }
        browser.rememberTerminalFileForReuse(resolvedURL, identity: targetIdentity)
        return true
    }
}
