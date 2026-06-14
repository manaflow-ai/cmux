import AppKit

extension CanvasRootView {
    func updateMinimap() {
        let visible = canvasRect(fromDocument: scrollView.contentView.documentVisibleRect)
        let focusedPaneID = model.layout.panes.first { pane in
            pane.panelIds.contains { descriptorsByPanelId[$0.rawValue]?.isFocused == true }
        }?.id
        let panes = model.layout.panes.map { pane in
            let frame: CGRect
            if let dragSession, dragSession.paneID == pane.id {
                frame = dragSession.lastFrame
            } else {
                frame = pane.frame.cgRect
            }
            return CanvasMinimapPaneSnapshot(id: pane.id, frame: frame)
        }
        let snapshot = CanvasMinimapSnapshot(
            panes: panes,
            visibleRect: visible,
            focusedPaneID: focusedPaneID
        )
        minimapView.snapshot = snapshot
        minimapView.isHidden = !snapshot.shouldShow
    }
}
