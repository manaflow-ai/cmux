import CmuxPanes
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: sourcePanelId
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        isRemoteTerminalSurface(sourcePanelId)
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard panels[sourcePanelId] != nil else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInCmux(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: sourcePanelId,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            return newBrowserSurface(inPane: targetPane, url: url, focus: true) != nil
        }
        return newBrowserSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            url: url
        ) != nil
    }

    func openOrFocusTerminalBrowserFileLink(url: URL, sourcePanelId: UUID) -> Bool {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = panels.values.compactMap({ $0 as? BrowserPanel }).first(where: {
            $0.localFileReadAccessPolicy == .fileOnly
                && $0.effectiveURLForTerminalFileReuse?
                    .standardizedFileURL.resolvingSymlinksInPath() == canonicalURL
        }) {
            focusPanel(existing.id)
            return true
        }

        if let targetPane = preferredRightSideTargetPane(fromPanelId: sourcePanelId) {
            return newBrowserSurface(
                inPane: targetPane,
                url: canonicalURL,
                focus: true,
                localFileReadAccessPolicy: .fileOnly
            ) != nil
        }
        return newBrowserSplit(
            from: sourcePanelId,
            orientation: .horizontal,
            url: canonicalURL,
            localFileReadAccessPolicy: .fileOnly
        ) != nil
    }
}
