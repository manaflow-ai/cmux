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
        holdMinimapVisible()
        updateMinimap(reveal: true)
    }

    func paneView(_ view: CanvasPaneView, draggedTo documentPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard var session = dragSession,
              let panelId = model.layout.selectedPanelId(in: session.paneID)?.rawValue else { return }
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
        session.lastPoint = documentPoint
        dragSession = session
        paneViews[session.paneID]?.frame = documentRect(fromCanvas: session.lastFrame)
        guidesView.setGuides(result.guides)
        updateJoinHighlight(for: session, at: documentPoint)
        updateMinimap(reveal: true)
        callbacks.onViewportGeometryChanged(window)
    }

    /// Live drop indicator: when this drag would join the dragged single-tab
    /// pane into another pane's tab bar (the same condition that commits a
    /// join in `paneViewDidEndDrag`), highlight that target's tab-bar rect.
    /// Anything else (over empty canvas, multi-tab source) clears it.
    private func updateJoinHighlight(for session: DragSession, at documentPoint: CGPoint) {
        guard case .titleBar = session.region,
              model.layout.panelIds(in: session.paneID)?.count == 1,
              let target = joinTarget(at: documentPoint, excluding: session.paneID),
              let targetView = paneViews[target] else {
            guidesView.setJoinHighlight(nil)
            return
        }
        var barRect = targetView.frame
        barRect.size.height = CanvasPaneTitleBarView.height
        guidesView.setJoinHighlight(barRect)
    }

    func paneViewDidEndDrag(_ view: CanvasPaneView) {
        guidesView.setJoinHighlight(nil)
        guard let session = dragSession else {
            releaseMinimapAfterInteraction()
            return
        }
        dragSession = nil
        defer {
            releaseMinimapAfterInteraction()
        }
        guidesView.setGuides([])
        guard let panelId = model.layout.selectedPanelId(in: session.paneID)?.rawValue else {
            updateMinimap(reveal: true)
            return
        }

        // Dropping a single-tab pane onto another pane's tab bar joins it as
        // a tab there (the canvas twin of bonsplit's tab drop).
        if model.layout.panelIds(in: session.paneID)?.count == 1,
           let target = joinTarget(at: session.lastPoint, excluding: session.paneID),
           let targetPanelId = model.layout.selectedPanelId(in: target)?.rawValue,
           model.joinPanel(panelId, withPaneContaining: targetPanelId) {
            reconcilePanes()
            applyZOrder()
            recomputeDocumentGeometry()
            applyAllPaneFrames()
            updateLifecycle()
            updateMinimap(reveal: true)
            callbacks.onLayoutChanged()
            callbacks.onFocusPanel(panelId)
            callbacks.onViewportGeometryChanged(window)
            return
        }

        model.setFrame(session.lastFrame, for: panelId)
        recomputeDocumentGeometry()
        applyAllPaneFrames()
        updateLifecycle()
        updateMinimap(reveal: true)
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    /// The pane whose tab bar contains the given document point, if any.
    private func joinTarget(at documentPoint: CGPoint, excluding excluded: CanvasPaneID) -> CanvasPaneID? {
        // Front-most first so overlapping bars resolve like clicks would.
        for pane in model.layout.panes.reversed() where pane.id != excluded {
            guard let paneView = paneViews[pane.id] else { continue }
            var barFrame = paneView.frame
            barFrame.size.height = CanvasPaneTitleBarView.height
            if barFrame.contains(documentPoint) {
                return pane.id
            }
        }
        return nil
    }

    func paneView(_ view: CanvasPaneView, requestTearOutTab panelId: UUID, atDocumentPoint point: CGPoint) {
        guard model.breakOutPanel(panelId) else {
            // Single-tab pane: nothing to tear out — degrade to a normal
            // pane drag so Option+drag never goes dead.
            if let frame = model.layout.frame(of: view.paneID)?.cgRect {
                dragSession = DragSession(
                    paneID: view.paneID,
                    region: .titleBar,
                    originalFrame: frame,
                    startPoint: point,
                    lastFrame: frame,
                    lastPoint: point
                )
                holdMinimapVisible()
                updateMinimap(reveal: true)
            }
            return
        }
        // Put the torn-out pane's tab bar under the cursor and drag from there.
        guard var frame = model.frame(of: panelId) else { return }
        let canvasPoint = canvasRect(fromDocument: CGRect(origin: point, size: .zero)).origin
        frame.origin = CGPoint(
            x: canvasPoint.x - min(60, frame.width / 4),
            y: canvasPoint.y - CanvasPaneTitleBarView.height / 2
        )
        model.setFrame(frame, for: panelId)
        reconcilePanes()
        applyZOrder()
        applyAllPaneFrames()
        guard let paneID = model.paneID(containing: panelId) else { return }
        dragSession = DragSession(
            paneID: paneID,
            region: .titleBar,
            originalFrame: frame,
            startPoint: point,
            lastFrame: frame,
            lastPoint: point
        )
        holdMinimapVisible()
        updateMinimap(reveal: true)
        callbacks.onFocusPanel(panelId)
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
        guard let panelId = selectedPanelId(of: view) else { return }
        if model.layout.paneIDs.last != view.paneID {
            model.bringToFront(panelId)
            applyZOrder()
            callbacks.onLayoutChanged()
        }
        callbacks.onFocusPanel(panelId)
        callbacks.onViewportGeometryChanged(window)
    }
}
