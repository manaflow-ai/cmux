/// One kind of layout motion. Each kind runs on one ``MotionBackend``, chosen kind by kind
/// (``MotionBackends``), so the kinds move to the render server one at a time, each in its own
/// file (plans/cmux-next/chrome-parity/p03-rendering.md, R2).
public nonisolated enum LayoutMotionKind: String, Sendable, CaseIterable {
    /// A split's and a close's pane and divider springs, with the camera shift a close carries.
    case splitClose
    /// A zoom and an unzoom: the zooming pane over the panes it covers (`PaneZoomMotion`).
    case zoom
    /// A pane or a dock column growing in from its edge (`PaneArrival`).
    case arrival
    /// The strip camera (`ScreenContentView.scroll`).
    case camera
    /// Each column's row camera (`ScreenContentView.stepRows`).
    case rows
    /// Each scroll area's camera (`ScreenContentView.stepAreas`).
    case areas
    /// A screen switch (the root's screen frames).
    case screens
    /// The canvas camera (`ScreenContentView.stepCanvasCamera`).
    case canvas
    /// The tab-drop highlight (`DropHighlightView`).
    case dropHighlight
    /// The sidebar showing and hiding.
    case sidebarSlide
}
