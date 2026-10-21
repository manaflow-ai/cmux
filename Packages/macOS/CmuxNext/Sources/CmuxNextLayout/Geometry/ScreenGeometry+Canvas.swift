public import CoreGraphics

extension ScreenGeometry {
    /// A canvas screen's geometry: every pane at its canvas frame, content
    /// space = canvas space, with no dividers, columns or docks. `visible` is
    /// the canvas rect the camera shows (the view's bounds).
    public static func canvas(_ canvas: CanvasScreen, visible: CGRect) -> ScreenGeometry {
        ScreenGeometry(viewport: visible.size, panes: canvas.frames, contentWidth: visible.width, isColumns: false,
                       stripWidth: visible.width, stripHeight: visible.height,
                       uncoveredMinX: visible.minX, uncoveredMaxX: visible.maxX, uncoveredMinY: visible.minY, uncoveredMaxY: visible.maxY,
                       clipMinX: visible.minX, clipMaxX: visible.maxX, clipMinY: visible.minY, clipMaxY: visible.maxY)
    }
}
