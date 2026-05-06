import Foundation
import Bonsplit

extension TabManager {
    func publishCmuxWorkspaceCreated(_ workspace: Workspace, selected: Bool) {
        CmuxEventBus.shared.publishWorkspaceCreated(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            selected: selected,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }

    func publishCmuxInitialSurfaceCreated(_ workspace: Workspace, selected: Bool) {
        guard let terminalPanel = workspace.focusedTerminalPanel else { return }
        workspace.publishCmuxSurfaceCreated(
            terminalPanel.id,
            paneId: workspace.paneId(forPanelId: terminalPanel.id),
            kind: "terminal",
            origin: "workspace_initial",
            focused: selected
        )
    }

    func publishCmuxWorkspaceClosed(_ workspace: Workspace) {
        CmuxEventBus.shared.publishWorkspaceClosed(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            remainingTabCount: tabs.count
        )
    }

    func publishCmuxWorkspaceSelected(_ workspace: Workspace) {
        CmuxEventBus.shared.publishWorkspaceSelected(
            workspaceId: workspace.id,
            title: workspace.cmuxEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }
}

extension Workspace {
    var cmuxEventWorkspaceTitle: String {
        customTitle ?? title
    }

    func publishCmuxSplitCreated(
        _ paneId: PaneID,
        sourcePaneId: PaneID?,
        orientation: SplitOrientation,
        surfaceId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        CmuxEventBus.shared.publishPaneCreated(
            workspaceId: id,
            paneId: paneId.id,
            sourcePaneId: sourcePaneId?.id,
            orientation: orientation.rawValue,
            surfaceId: surfaceId,
            origin: origin
        )
        if let surfaceId {
            publishCmuxSurfaceCreated(surfaceId, paneId: paneId, kind: kind, origin: origin, focused: focused)
        }
    }

    func publishCmuxSurfaceCreated(
        _ surfaceId: UUID,
        paneId: PaneID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        CmuxEventBus.shared.publishSurfaceCreated(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: kind,
            origin: origin,
            focused: focused
        )
    }

    func publishCmuxSurfaceClosed(_ surfaceId: UUID, paneId: PaneID?, panel: (any Panel)?, origin: String) {
        CmuxEventBus.shared.publishSurfaceClosed(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: panel.map(Self.cmuxEventSurfaceKind),
            origin: origin
        )
    }

    func publishCmuxPaneClosed(_ paneId: PaneID, closedPanelIds: [UUID], origin: String) {
        CmuxEventBus.shared.publishPaneClosed(
            workspaceId: id,
            paneId: paneId.id,
            closedSurfaceIds: closedPanelIds,
            origin: origin
        )
    }

    private static func cmuxEventSurfaceKind(_ panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return "terminal"
        case .browser:
            return "browser"
        case .markdown:
            return "markdown"
        case .filePreview:
            return "file_preview"
        }
    }
}
