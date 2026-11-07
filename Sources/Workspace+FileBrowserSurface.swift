import Bonsplit
import Foundation

extension Workspace {
    /// Opens one file-browser tab per pane, rooted to that pane's terminal directory.
    @discardableResult
    func openOrFocusFileBrowserSurface(
        inPane paneID: PaneID,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        openOrFocusRepositoryToolSurface(inPane: paneID, mode: .files, focus: focus)
    }

    /// Opens one Git Graph tab per pane, rooted to that pane's terminal repository.
    @discardableResult
    func openOrFocusGitGraphSurface(
        inPane paneID: PaneID,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        openOrFocusRepositoryToolSurface(inPane: paneID, mode: .gitGraph, focus: focus)
    }

    /// Opens the cross-workspace Herd control surface, reusing the existing surface.
    @discardableResult
    func openOrFocusHerdSurface(
        inPane paneID: PaneID,
        focus: Bool = true
    ) -> RightSidebarToolPanel? {
        openOrFocusRightSidebarToolSurface(inPane: paneID, mode: .herd, focus: focus)
    }

    private func openOrFocusRepositoryToolSurface(
        inPane paneID: PaneID,
        mode: RightSidebarMode,
        focus: Bool
    ) -> RightSidebarToolPanel? {
        if let existing = bonsplitController.tabs(inPane: paneID).compactMap({ tab in
            panelIdFromSurfaceId(tab.id).flatMap { panels[$0] as? RightSidebarToolPanel }
        }).first(where: { $0.mode == mode }) {
            if focus {
                focusPanel(existing.id)
            }
            return existing
        }

        let sourcePanelID = repositoryToolSourceTerminalID(inPane: paneID)
        let sourceDirectory = repositoryToolDirectory(
            sourcePanelID: sourcePanelID,
            rootDirectory: nil
        )

        return newRightSidebarToolSurface(
            inPane: paneID,
            mode: mode,
            focus: focus,
            sourcePanelID: sourcePanelID,
            rootDirectory: sourceDirectory
        )
    }

    private func repositoryToolSourceTerminalID(inPane paneID: PaneID) -> UUID? {
        if let selectedTab = bonsplitController.selectedTab(inPane: paneID),
           let selectedPanelID = panelIdFromSurfaceId(selectedTab.id),
           terminalPanel(for: selectedPanelID) != nil {
            return selectedPanelID
        }

        return bonsplitController.tabs(inPane: paneID).reversed().compactMap { tab in
            panelIdFromSurfaceId(tab.id)
        }.first(where: { terminalPanel(for: $0) != nil })
    }

    func repositoryToolDirectory(sourcePanelID: UUID?, rootDirectory: String?) -> String? {
        func normalized(_ directory: String?) -> String? {
            guard let directory else { return nil }
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let sourcePanelID {
            let runtimeDirectory = terminalPanel(for: sourcePanelID)?.directory
            if let directory = effectivePanelDirectory(
                panelId: sourcePanelID,
                localFallback: runtimeDirectory
            ) {
                return directory
            }
        }
        if let rootDirectory = normalized(rootDirectory) {
            return rootDirectory
        }
        let workspaceDirectory = usesRemoteDirectoryProvenance
            ? normalized(trustedRemoteCurrentDirectory)
            : normalized(currentDirectory)
        if let workspaceDirectory {
            return workspaceDirectory
        }
        return nil
    }
}
