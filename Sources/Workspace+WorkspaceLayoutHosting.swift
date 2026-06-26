import Bonsplit
import CmuxBrowser
import CmuxWorkspaces
import CoreGraphics
import Foundation

/// `Workspace` is the live host for its ``WorkspaceLayoutCoordinator``. Each
/// member reproduces the reads and side effects the legacy cmux.json
/// custom-layout bodies performed inline against the `BonsplitController` split
/// tree, the workspace surface-creation methods, and the panel registry. Surface
/// creation returns only the new panel id; the app-target panel types never cross
/// into the package. The coordinator is held by `Workspace` and references this
/// host weakly, so there is no retain cycle.
extension Workspace: WorkspaceLayoutHosting {
    func layoutRootPaneId() -> PaneID? {
        bonsplitController.allPaneIds.first
    }

    func layoutPanelIds(inPane paneId: PaneID) -> [UUID] {
        bonsplitController
            .tabs(inPane: paneId)
            .compactMap { panelIdFromSurfaceId($0.id) }
    }

    func layoutCreateTerminalSurface(inPane paneId: PaneID, focus: Bool) -> UUID? {
        newTerminalSurface(inPane: paneId, focus: focus)?.id
    }

    func layoutCreateTerminalSurface(
        inPane paneId: PaneID,
        focus: Bool,
        workingDirectory: String,
        startupEnvironment: [String: String]
    ) -> UUID? {
        newTerminalSurface(
            inPane: paneId,
            focus: focus,
            workingDirectory: workingDirectory,
            startupEnvironment: startupEnvironment
        )?.id
    }

    func layoutCreateTerminalSplit(
        fromPanelId panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool,
        focus: Bool
    ) -> UUID? {
        newTerminalSplit(
            from: panelId,
            orientation: orientation,
            insertFirst: insertFirst,
            focus: focus
        )?.id
    }

    func layoutCreateBrowserSurface(inPane paneId: PaneID, url: URL?, focus: Bool) -> UUID? {
        newBrowserSurface(
            inPane: paneId,
            url: url,
            focus: focus,
            creationPolicy: .restoration
        )?.id
    }

    func layoutCreateProjectSurface(inPane paneId: PaneID, projectPath: String, focus: Bool) -> UUID? {
        newProjectSurface(
            inPane: paneId,
            projectPath: projectPath,
            focus: focus
        )?.id
    }

    func layoutPaneId(forPanelId panelId: UUID) -> PaneID? {
        paneId(forPanelId: panelId)
    }

    func layoutClosePanel(_ panelId: UUID, force: Bool) {
        _ = closePanel(panelId, force: force)
    }

    func layoutSetPanelCustomTitle(panelId: UUID, title: String) {
        _ = setPanelCustomTitle(panelId: panelId, title: title)
    }

    func layoutSendStartupCommand(_ command: String, toTerminalPanelId panelId: UUID) {
        guard let terminal = terminalPanel(for: panelId) else { return }
        sendInputWhenReady(command, to: terminal)
    }

    func layoutResolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        CmuxConfigStore.resolveCwd(cwd, relativeTo: baseCwd)
    }

    func layoutTreeSnapshot() -> ExternalTreeNode {
        bonsplitController.treeSnapshot()
    }

    func layoutApplySplitDividerPosition(_ position: CGFloat, forSplit splitId: UUID) {
        _ = bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
    }

    func layoutFocusPanel(_ panelId: UUID) {
        focusPanel(panelId)
    }
}
