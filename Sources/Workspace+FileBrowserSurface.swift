import Bonsplit
import Foundation

extension Workspace {
    /// Opens one file-browser tab per pane, rooted to that pane's terminal directory.
    @discardableResult
    func openOrFocusFileBrowserSurface(
        inPane paneID: PaneID,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        if let existing = bonsplitController.tabs(inPane: paneID).compactMap({ tab in
            panelIdFromSurfaceId(tab.id).flatMap { panels[$0] as? RightSidebarToolPanel }
        }).first(where: { $0.mode == .files }) {
            if focus {
                focusPanel(existing.id)
            }
            return existing
        }

        let sourcePanelID = fileBrowserSourceTerminalID(inPane: paneID)
        let sourceDirectory = sourcePanelID.flatMap { panelID in
            effectivePanelDirectory(
                panelId: panelID,
                localFallback: terminalPanel(for: panelID)?.directory
            )
        } ?? defaultFileBrowserDirectory

        return newRightSidebarToolSurface(
            inPane: paneID,
            mode: .files,
            focus: focus,
            sourcePanelID: sourcePanelID,
            rootDirectory: sourceDirectory
        )
    }

    private func fileBrowserSourceTerminalID(inPane paneID: PaneID) -> UUID? {
        if let selectedTab = bonsplitController.selectedTab(inPane: paneID),
           let selectedPanelID = panelIdFromSurfaceId(selectedTab.id),
           terminalPanel(for: selectedPanelID) != nil {
            return selectedPanelID
        }

        return bonsplitController.tabs(inPane: paneID).reversed().compactMap { tab in
            panelIdFromSurfaceId(tab.id)
        }.first(where: { terminalPanel(for: $0) != nil })
    }

    private var defaultFileBrowserDirectory: String? {
        let candidate = usesRemoteDirectoryProvenance
            ? trustedRemoteCurrentDirectory
            : currentDirectory
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            return trimmed
        }
        return usesRemoteDirectoryProvenance
            ? nil
            : FileManager.default.homeDirectoryForCurrentUser.path
    }
}
