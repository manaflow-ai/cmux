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

    func terminalLinkBrowserProfileID(for sourcePanelId: UUID) -> UUID? {
        guard paneId(forPanelId: sourcePanelId) != nil else { return nil }
        return BrowserPanel.resolvedProfileID(requested: nil)
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
        let intendedProfileID = terminalLinkBrowserProfileID(for: sourcePanelId)
        let preferredProfileID = intendedProfileID.flatMap { profileID in
            BrowserPrewarmedWebViewPool.shared.hasEntry(url: url, profileID: profileID)
                ? profileID
                : nil
        }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            return newSurface(
                kind: .browser,
                inPane: targetPane,
                url: url,
                focus: true,
                preferredProfileID: preferredProfileID
            ) != nil
        }
        return newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: sourcePanelId,
            url: url,
            preferredProfileID: preferredProfileID,
            focus: true
        ) != nil
    }
}
