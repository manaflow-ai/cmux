public import AppKit
import CmuxCanvas

extension CanvasPagesRootView: CanvasViewportControlling {
    /// Rebuilds arranged pages after a model mutation outside the native page controller.
    public func modelDidChangeExternally(animated: Bool) {
        let selectedPanel = latestFocusedPanelId ?? selectedPageObject()?.selectedPanelId
        pageObjects = orderedPageObjects(from: model.layout)
        pageController.arrangedObjects = pageObjects
        if let index = indexForPanel(selectedPanel) ?? selectedPaneID.flatMap(indexForPane) {
            selectPage(at: index, animated: animated, suppressFocus: true)
        }
        refreshPreparedControllers()
        callbacks.onLayoutChanged()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Selects the native page containing the requested panel.
    public func revealPane(_ panelId: UUID, animated: Bool) {
        guard let paneID = model.paneID(containing: panelId),
              indexForPane(paneID) != nil else { return }
        model.selectPanel(panelId)
        pageObjects = orderedPageObjects(from: model.layout)
        pageController.arrangedObjects = pageObjects
        guard let index = indexForPane(paneID) else { return }
        selectPage(at: index, animated: false, suppressFocus: true)
        refreshPreparedControllers()
        callbacks.onViewportGeometryChanged(window)
    }

    /// Pages mode has no overview state to toggle.
    public func toggleOverview() {}

    /// Pages mode keeps native page scale fixed at 100%.
    public func zoom(by factor: CGFloat) {}

    /// Pages mode keeps native page scale fixed at 100%.
    public func resetZoom() {}

    /// Pages mode always reports 100% magnification.
    public var currentMagnification: CGFloat {
        1
    }

    /// Center point of the currently selected page in canvas coordinates.
    public var currentCenterInCanvas: CGPoint {
        guard let object = selectedPageObject(),
              let frame = model.layout.frame(of: object.paneID)?.cgRect else {
            return .zero
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Panel ids whose page controllers are currently attached and rendering.
    public var renderedPanelIds: Set<UUID> {
        renderedPagePanelIds()
    }

    /// Selects the native page whose canvas frame is nearest to the requested center.
    public func setViewport(center: CGPoint, magnification: CGFloat?) {
        guard let nearest = pageObjects.enumerated().min(by: { lhs, rhs in
            distanceSquared(from: lhs.element.pane.frame.cgRect, to: center) <
                distanceSquared(from: rhs.element.pane.frame.cgRect, to: center)
        }) else {
            return
        }
        selectPage(at: nearest.offset, animated: false, suppressFocus: true)
        refreshPreparedControllers()
        callbacks.onViewportGeometryChanged(window)
    }

    private func distanceSquared(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }
}
