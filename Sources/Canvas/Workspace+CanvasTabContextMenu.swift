import AppKit
import Bonsplit
import CmuxCanvas

extension Workspace {
    func canvasTabContextMenu(for panelId: UUID) -> NSMenu? {
        guard layoutMode == .canvas,
              let canvasPaneId = canvasModel.paneID(containing: panelId),
              let panelIds = canvasModel.layout.panelIds(in: canvasPaneId),
              let paneId = bonsplitPaneId(forPanelId: panelId),
              let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        let visibleTabIds = panelIds.compactMap { surfaceIdFromPanelId($0.rawValue) }
        return bonsplitController.makeTabContextMenu(
            for: tabId,
            inPane: paneId,
            visibleTabIds: visibleTabIds,
            excludingActions: [.move, .moveToLeftPane, .moveToRightPane, .toggleZoom, .toggleFullWidthTab]
        )
    }

    func handleCanvasTabContextAction(
        _ action: TabContextAction,
        tab: Bonsplit.Tab,
        inPane pane: PaneID
    ) -> Bool {
        guard layoutMode == .canvas,
              let panelId = panelIdFromSurfaceId(tab.id),
              let canvasPaneId = canvasModel.paneID(containing: panelId),
              let panelIds = canvasModel.layout.panelIds(in: canvasPaneId),
              let index = panelIds.firstIndex(of: CanvasPanelID(rawValue: panelId)) else { return false }

        switch action {
        case .closeToLeft:
            closeTabsFromContextMenu(panelIds.prefix(index).map { TabID(uuid: $0.rawValue) })
            return true
        case .closeToRight:
            closeTabsFromContextMenu(panelIds.dropFirst(index + 1).map { TabID(uuid: $0.rawValue) })
            return true
        case .closeOthers:
            closeTabsFromContextMenu(panelIds.filter { $0.rawValue != panelId }.map { TabID(uuid: $0.rawValue) })
            return true
        case .newTerminalToRight:
            guard let newPanel = newTerminalSurface(inPane: pane, focus: true) else { return true }
            joinNewPanelIntoCanvasPane(newPanel.id, anchor: panelId, at: index + 1)
            return true
        case .newBrowserToRight:
            guard let newPanel = newBrowserSurface(inPane: pane, focus: true) else { return true }
            joinNewPanelIntoCanvasPane(newPanel.id, anchor: panelId, at: index + 1)
            return true
        case .duplicate:
            guard let newPanel = duplicateBrowserToRight(panelId: panelId, focus: true) else { return true }
            joinNewPanelIntoCanvasPane(newPanel.id, anchor: panelId, at: index + 1)
            return true
        default:
            return false
        }
    }
}
