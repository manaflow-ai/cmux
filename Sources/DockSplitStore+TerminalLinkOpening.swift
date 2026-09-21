import AppKit
import CmuxPanes
import CmuxSettings
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

    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? {
        guard let resource = SurfaceCatalog.shared.resource(forPanel: sourcePanelId),
              let address = SurfaceCatalog.shared.machineInfo(for: resource.machine)?.privateAddress,
              let target = CmuxTuiSurfaceProvider.cloudTerminalLinkTarget(url: url, resource: resource, privateAddress: address) else { return nil }
        return target
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

    func openTerminalBrowserLink(
        url: URL,
        sourcePanelId: UUID,
        placement: TerminalLinkBrowserPlacement,
        focus: Bool = true
    ) -> Bool {
        guard let panelId = panelID(forTerminalLinkSourceID: sourcePanelId),
              paneId(forPanelId: panelId) != nil else {
            return false
        }
        if focus { noteKeyboardFocusIntent(window: NSApp.keyWindow ?? NSApp.mainWindow) }
        return BrowserSplitContainer.dock(self).openBrowser(
            of: panelId,
            placement: placement,
            request: BrowserSplitRequest(url: url, focus: focus, preloadInBackground: false)
        ) != nil
    }
}
