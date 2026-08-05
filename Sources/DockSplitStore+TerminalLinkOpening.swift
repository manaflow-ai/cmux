import CmuxBrowser
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
        guard let terminal = panels[sourcePanelId] as? TerminalPanel else { return nil }
        if terminalLinkIsRemoteTerminal(sourcePanelId) {
            return terminalLinkHoverWorkingDirectory(for: sourcePanelId)
        }
        // Click routing accepts only the live process CWD or the latest OSC 7
        // report. Requested and transfer directories remain hover hints because
        // they can lag after a local process changes directories.
        return terminalWorkingDirectoryResolver
            .liveForegroundProcessWorkingDirectory(for: terminal)
            ?? TerminalWorkingDirectoryResolver.normalized(
                terminal.surface.reportedWorkingDirectory
            )
    }

    func terminalLinkHoverWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let terminal = panels[sourcePanelId] as? TerminalPanel else { return nil }
        let transfer = detachedSurfaceTransfersByPanelId[sourcePanelId]
        if transfer?.isRemoteTerminal == true {
            return TerminalWorkingDirectoryResolver.firstAvailable([
                transfer?.directory,
                terminal.directory,
                terminal.requestedWorkingDirectory,
            ])
        }

        let cachedCandidates = [
            terminal.directory,
            transfer?.directory,
            terminal.requestedWorkingDirectory,
        ]
        let reportedDirectory = terminal.surface.reportedWorkingDirectory
        if restoredAgentLifecycle.resumeStatesByPanelId[sourcePanelId] == .autoResumeCommandRunning {
            return TerminalWorkingDirectoryResolver.firstAvailable([
                restoredResumeSessionWorkingDirectoriesByPanelId[sourcePanelId],
            ] + cachedCandidates + [
                reportedDirectory,
            ])
        }
        return TerminalWorkingDirectoryResolver.firstAvailable([
            reportedDirectory,
        ] + cachedCandidates)
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
        resolvedFileURL _: URL?,
        fallback _: @escaping @MainActor @Sendable () -> Void,
        completion _: @escaping @MainActor @Sendable () -> Void
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

    func openOrFocusTerminalBrowserFileLink(resolvedURL: URL, sourcePanelId: UUID) -> Bool {
        guard let targetIdentity = BrowserLocalFileIdentity(resolvedURL: resolvedURL) else { return false }
        if let existing = panels.values.compactMap({ $0 as? BrowserPanel }).first(where: {
            $0.canReuseTerminalFile(resolvedURL, identity: targetIdentity)
        }), existing.reloadTerminalFileForReuse(resolvedURL, identity: targetIdentity) {
            focusPanel(existing.id)
            return true
        }

        guard let sourcePane = paneId(forPanelId: sourcePanelId) else { return false }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            guard let browserID = newSurface(
                kind: .browser,
                inPane: targetPane,
                url: resolvedURL,
                focus: true,
                bypassRemoteProxy: true,
                localFileReadAccessPolicy: .fileOnly
            ), let browser = panels[browserID] as? BrowserPanel else {
                return false
            }
            browser.rememberTerminalFileForReuse(resolvedURL, identity: targetIdentity)
            return true
        }
        guard let browserID = newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: sourcePanelId,
            url: resolvedURL,
            bypassRemoteProxy: true,
            localFileReadAccessPolicy: .fileOnly,
            focus: true
        ), let browser = panels[browserID] as? BrowserPanel else {
            return false
        }
        browser.rememberTerminalFileForReuse(resolvedURL, identity: targetIdentity)
        return true
    }
}
