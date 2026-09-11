import AppKit
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
            sourcePanelId: sourcePanelId,
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
