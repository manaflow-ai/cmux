import CmuxPanes
import Foundation

extension DockSplitStore: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "dock:\(workspaceId.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        terminalWorkingDirectory(for: sourcePanelId)
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        detachedSurfaceTransfersByPanelId[sourcePanelId]?.isRemoteTerminal == true
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId _: UUID,
        filePath _: String,
        fallback _: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        // The Dock currently hosts terminal and browser panels only. Returning
        // false makes the shared coordinator hand the resolved file to macOS.
        false
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID) -> Bool {
        guard let sourcePane = paneId(forPanelId: sourcePanelId) else { return false }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            return newSurface(
                kind: .browser,
                inPane: targetPane,
                url: url,
                focus: true
            ) != nil
        }
        return newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: sourcePanelId,
            url: url,
            focus: true
        ) != nil
    }

    func openOrFocusTerminalBrowserFileLink(url: URL, sourcePanelId: UUID) -> Bool {
        let canonicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = panels.values.compactMap({ $0 as? BrowserPanel }).first(where: {
            $0.localFileReadAccessPolicy == .fileOnly
                && $0.currentURL?.standardizedFileURL.resolvingSymlinksInPath() == canonicalURL
        }) {
            focusPanel(existing.id)
            return true
        }

        guard let sourcePane = paneId(forPanelId: sourcePanelId) else { return false }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            return newSurface(
                kind: .browser,
                inPane: targetPane,
                url: canonicalURL,
                focus: true,
                localFileReadAccessPolicy: .fileOnly
            ) != nil
        }
        return newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: sourcePanelId,
            url: canonicalURL,
            focus: true,
            localFileReadAccessPolicy: .fileOnly
        ) != nil
    }
}
