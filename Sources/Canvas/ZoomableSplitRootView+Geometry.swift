import AppKit
import Bonsplit
import CmuxCanvas

extension ZoomableSplitRootView {
    func canvasRect(from rect: CGRect) -> CanvasRect {
        CanvasRect(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    func canvasPoint(from point: CGPoint) -> CanvasPoint {
        CanvasPoint(x: Double(point.x), y: Double(point.y))
    }

    func canvasSize(from size: CGSize) -> CanvasSize {
        CanvasSize(width: Double(size.width), height: Double(size.height))
    }

    func cgPoint(from point: CanvasPoint) -> CGPoint {
        CGPoint(x: point.x, y: point.y)
    }

    static func selectedPanelId(
        atDocumentPoint point: CGPoint,
        in snapshot: LayoutSnapshot,
        panelIdFromSurfaceId: (TabID) -> UUID?
    ) -> UUID? {
        for pane in snapshot.panes.reversed() {
            let paneFrame = CGRect(
                x: pane.frame.x - snapshot.containerFrame.x,
                y: pane.frame.y - snapshot.containerFrame.y,
                width: pane.frame.width,
                height: pane.frame.height
            )
            guard paneFrame.contains(point) else { continue }
            guard let tabIdString = pane.selectedTabId ?? pane.tabIds.first,
                  let tabUUID = UUID(uuidString: tabIdString) else {
                return nil
            }
            return panelIdFromSurfaceId(TabID(uuid: tabUUID))
        }
        return nil
    }

    func focusedPane(in snapshot: LayoutSnapshot) -> PaneGeometry? {
        guard let focusedPaneId = snapshot.focusedPaneId else { return nil }
        return snapshot.panes.first { $0.paneId == focusedPaneId }
    }
}
