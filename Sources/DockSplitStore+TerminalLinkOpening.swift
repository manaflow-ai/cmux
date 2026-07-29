import CmuxPanes
import Foundation

extension DockSplitStore: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "dock:\(workspaceId.uuidString)"
    }

    func terminalLinkContainsPanel(_ sourcePanelId: UUID) -> Bool {
        containsPanel(sourcePanelId)
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard !terminalLinkIsRemoteTerminal(sourcePanelId),
              let terminal = panels[sourcePanelId] as? TerminalPanel else {
            return nil
        }
        let transfer = detachedSurfaceTransfersByPanelId[sourcePanelId]
        return TerminalWorkingDirectoryResolver.firstAvailable([
            terminal.surface.reportedWorkingDirectory,
            terminal.directory,
            transfer?.directory,
            terminal.requestedWorkingDirectory,
        ])
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        detachedSurfaceTransfersByPanelId[sourcePanelId]?.isRemoteTerminal == true
    }

    func terminalLinkSnapshotTerminalPanel(for sourcePanelId: UUID) -> TerminalPanel? {
        guard !terminalLinkIsRemoteTerminal(sourcePanelId) else { return nil }
        return panels[sourcePanelId] as? TerminalPanel
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
                bypassRemoteProxy: true,
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
            bypassRemoteProxy: true,
            localFileReadAccessPolicy: .fileOnly
        ) != nil
    }
}
