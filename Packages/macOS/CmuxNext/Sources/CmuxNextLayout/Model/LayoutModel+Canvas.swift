public import CoreGraphics

/// Canvas layout (plans/cmux-next/canvas-layout.md): a screen shown as free-placed
/// panes on a zoomable, pannable plane. Client-local; the daemon keeps the screen's
/// tree, and every apply reconciles each canvas with its screen's panes.
extension LayoutModel {
    /// The canvas of `screen`, when it shows as one.
    public func canvas(for screen: ScreenID) -> CanvasScreen? {
        canvases[screen]
    }

    /// The active screen's canvas.
    public var activeCanvas: CanvasScreen? {
        activeScreenID.flatMap { canvases[$0] }
    }

    /// The active screen shows as a canvas now: in canvas mode, with no
    /// zoomed pane (a zoom shows its pane full size over the canvas).
    public var isCanvasActive: Bool {
        guard let screen = activeScreen else { return false }
        return canvases[screen.id] != nil && !screen.zoomed
    }

    /// The canvas a canvas action works on: the screen holding `pane`, else
    /// the active screen.
    public func canvasScreenID(containing pane: PaneID? = nil) -> ScreenID? {
        let id = pane.flatMap { screen(containing: $0)?.id } ?? activeScreenID
        return id.flatMap { canvases[$0] != nil ? $0 : nil }
    }

    /// Shows `screen` (default: the active one) as a canvas whose panes
    /// start at `seed` (view points of a `viewport`-sized view: what shows
    /// now, so the screen looks the same), or shows its daemon layout again.
    /// Returns whether the screen is a canvas now.
    @discardableResult
    public func toggleCanvas(screen id: ScreenID? = nil, seed: [PaneID: CGRect], viewport: CGSize) -> Bool {
        guard let id = id ?? activeScreenID, let screen = screens.first(where: { $0.id == id }) else { return false }
        if canvases[id] != nil {
            canvases[id] = nil
            canvasViewports[id] = nil
            return false
        }
        var canvas = CanvasScreen(seed: seed.filter { screen.layout.contains($0.key) }, viewport: viewport)
        if !screen.zoomed { canvas.reconcile(panes: screen.layout.panes, anchor: focusedPane) }
        canvases[id] = canvas
        canvasViewports[id] = viewport
        return true
    }

    /// Moves or resizes `pane` on its canvas (a drag frame, or its end).
    /// The pane comes to the front when a drag begins.
    public func setCanvasFrame(_ frame: CGRect, for pane: PaneID, raise: Bool = false) {
        guard let id = canvasScreenID(containing: pane), var canvas = canvases[id], canvas.frames[pane] != nil else { return }
        canvas.setFrame(frame, for: pane)
        if raise { canvas.bringToFront(pane) }
        if canvas != canvases[id] { canvases[id] = canvas }
    }

    /// Sets the camera of `screen`'s canvas (a pan or a pinch ended).
    public func setCanvasCamera(_ camera: CanvasCamera, for screen: ScreenID) {
        guard var canvas = canvases[screen], canvas.camera != camera else { return }
        canvas.camera = camera
        canvases[screen] = canvas
    }

    /// Zooms the canvas holding `pane` (default: the active one) by `factor`
    /// about the viewport center. Returns false when there is no canvas or
    /// the zoom is at its limit.
    @discardableResult
    public func zoomCanvas(by factor: Double, containing pane: PaneID? = nil) -> Bool {
        guard let id = canvasScreenID(containing: pane), let camera = canvases[id]?.camera else { return false }
        return changeCamera(id, to: camera.zoomed(by: factor))
    }

    /// Zoom 1 about the viewport center. Returns false when there is no
    /// canvas or it is at zoom 1.
    @discardableResult
    public func resetCanvasZoom(containing pane: PaneID? = nil) -> Bool {
        guard let id = canvasScreenID(containing: pane), let camera = canvases[id]?.camera else { return false }
        return changeCamera(id, to: camera.zoomed(to: 1))
    }

    /// The view of `screen` measured its viewport.
    public func reportCanvasViewport(_ size: CGSize, for screen: ScreenID) {
        guard canvases[screen] != nil else { return }
        canvasViewports[screen] = size
    }

    /// Pans the camera of `screen` the least that shows `pane`.
    func revealOnCanvas(_ pane: PaneID, screen id: ScreenID) {
        guard let canvas = canvases[id], let frame = canvas.frames[pane], let viewport = canvasViewports[id] else { return }
        _ = changeCamera(id, to: canvas.camera.revealing(frame, viewport: viewport, margin: CanvasScreen.gap))
    }

    private func changeCamera(_ id: ScreenID, to camera: CanvasCamera) -> Bool {
        guard var canvas = canvases[id], canvas.camera != camera else { return false }
        canvas.camera = camera
        canvases[id] = canvas
        return true
    }

    /// Every canvas holds its screen's panes (a split's new pane gets a free
    /// frame beside the focused pane), and a screen that left drops its canvas.
    func reconcileCanvases() {
        guard !canvases.isEmpty else { return }
        var next = canvases
        for id in next.keys {
            guard let screen = screens.first(where: { $0.id == id }) else {
                next[id] = nil
                canvasViewports[id] = nil
                continue
            }
            // A zoomed screen lists only its zoomed pane: the canvas keeps the others for after.
            guard !screen.zoomed else { continue }
            next[id]?.reconcile(panes: screen.layout.panes, anchor: focusedPane)
        }
        guard next != canvases else { return }
        // The focus a split asked for can land before its pane: the camera shows the pane once placed.
        let placedFocus = focusedPane.flatMap { pane in next.first { $0.value.frames[pane] != nil && canvases[$0.key]?.frames[pane] == nil }?.key }
        canvases = next
        if let pane = focusedPane, let id = placedFocus { revealOnCanvas(pane, screen: id) }
    }
}
