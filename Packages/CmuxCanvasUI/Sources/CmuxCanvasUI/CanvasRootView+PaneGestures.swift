import AppKit
import CmuxCanvas

// MARK: - CanvasPaneViewDelegate

extension CanvasRootView: CanvasPaneViewDelegate {
    /// The selected panel of a pane view, used for panel-keyed model calls.
    private func selectedPanelId(of view: CanvasPaneView) -> UUID? {
        model.layout.selectedPanelId(in: view.paneID)?.rawValue
    }

    func paneView(_ view: CanvasPaneView, mouseDownAt documentPoint: CGPoint, region: CanvasPaneHitRegion) {
        guard let frame = model.layout.frame(of: view.paneID)?.cgRect else { return }
        dragSession = DragSession(
            paneID: view.paneID,
            region: region,
            originalFrame: frame,
            startPoint: documentPoint,
            lastFrame: frame
        )
        if let panelId = selectedPanelId(of: view) {
            model.bringToFront(panelId)
        }
        applyZOrder()
    }

    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = dragSession, session.paneID == view.paneID,
              let panelId = selectedPanelId(of: view) else { return }
        let dx = documentPoint.x - session.startPoint.x
        let dy = documentPoint.y - session.startPoint.y
        // Holding Command suspends snapping for free-form placement.
        let snapping = !modifiers.contains(.command)

        let result: CanvasSnapResult
        switch session.region {
        case .titleBar:
            let proposed = session.originalFrame.offsetBy(dx: dx, dy: dy)
            result = model.snapForMove(proposed: proposed, movingPanelId: panelId, snapping: snapping)
        case .resize(let edges):
            var proposed = session.originalFrame
            if edges.contains(.left) {
                proposed.origin.x += dx
                proposed.size.width = max(1, proposed.size.width - dx)
            } else if edges.contains(.right) {
                proposed.size.width = max(1, proposed.size.width + dx)
            }
            if edges.contains(.top) {
                proposed.origin.y += dy
                proposed.size.height = max(1, proposed.size.height - dy)
            } else if edges.contains(.bottom) {
                proposed.size.height = max(1, proposed.size.height + dy)
            }
            result = model.snapForResize(
                proposed: proposed,
                edges: edges,
                panelId: panelId,
                snapping: snapping
            )
        }

        session.lastFrame = result.frame.cgRect
        dragSession = session
        view.frame = documentRect(fromCanvas: session.lastFrame)
        guidesView.setGuides(result.guides)
        callbacks.onViewportGeometryChanged(window)
    }

    func paneViewDidEndDrag(_ view: CanvasPaneView) {
        guard let session = dragSession, session.paneID == view.paneID,
              let panelId = selectedPanelId(of: view) else { return }
        dragSession = nil
        guidesView.setGuides([])
        model.setFrame(session.lastFrame, for: panelId)
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    func paneView(_ view: CanvasPaneView, didSelectTab panelId: UUID) {
        model.selectPanel(panelId)
        if let pane = model.layout.panes.first(where: { $0.id == view.paneID }) {
            reconcileMount(for: pane, in: view)
            view.updateChrome(chrome(for: pane))
        }
        callbacks.onFocusPanel(panelId)
        callbacks.onViewportGeometryChanged(window)
    }

    func paneView(_ view: CanvasPaneView, didCloseTab panelId: UUID) {
        callbacks.onClosePanel(panelId)
    }

    func paneViewDidRequestFocus(_ view: CanvasPaneView) {
        if let panelId = selectedPanelId(of: view) {
            callbacks.onFocusPanel(panelId)
        }
    }
}
