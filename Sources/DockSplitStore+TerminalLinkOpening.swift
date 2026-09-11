import AppKit
import CmuxPanes
import Foundation

extension DockSplitStore: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "dock:\(workspaceId.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId) else {
            return nil
        }
        return terminalWorkingDirectory(for: panelId)
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId) else {
            return false
        }
        return detachedSurfaceTransfersByPanelId[panelId]?.isRemoteTerminal == true
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
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId),
              let sourcePane = paneId(forPanelId: panelId) else { return false }
        if let targetPane = BrowserRightSidePaneResolver().preferredPane(
            from: sourcePane,
            in: bonsplitController
        ) {
            noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
            guard let panelId = newSurface(
                kind: .browser,
                inPane: targetPane,
                url: url,
                focus: false
            ) else { return false }
            focusPanelFromDockInteraction(
                panelId,
                window: NSApp.keyWindow ?? NSApp.mainWindow
            )
            return true
        }
        noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow)
        guard let panelId = newSplit(
            kind: .browser,
            orientation: .horizontal,
            insertFirst: false,
            sourcePanelId: panelId,
            url: url,
            focus: false
        ) else { return false }
        focusPanelFromDockInteraction(
            panelId,
            window: NSApp.keyWindow ?? NSApp.mainWindow
        )
        return true
    }
}
