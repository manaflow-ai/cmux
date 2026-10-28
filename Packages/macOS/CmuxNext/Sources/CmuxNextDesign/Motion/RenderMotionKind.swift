/// One kind of motion that can move from the main thread to the render server, one kind at a time
/// (plans/cmux-next/chrome-parity/p03-rendering.md, R2). Each kind has one host, the view whose
/// change turn starts it, and that host's registration file lists its variants:
/// - `ScreenContentView` (`ScreenContentView+Motion.swift`): ``splitClose``, ``zoom``, ``arrival``,
///   ``camera``, ``rows``, ``areas``, ``canvas``.
/// - `LayoutRootView` (`LayoutRootView+Motion.swift`): ``screens``, ``dropHighlight``.
/// - `SidebarContainerView` (`SidebarContainerView+RenderSlide.swift`): ``sidebarSlide``. The seam lives
///   here in CmuxNextDesign so the sidebar registers without depending on CmuxNextLayout.
public nonisolated enum RenderMotionKind: String, Sendable, CaseIterable {
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
    /// The canvas camera (`ScreenContentView.stepCanvasCamera`).
    case canvas
    /// A screen switch (`LayoutRootView.screenFrames`).
    case screens
    /// The tab-drop highlight (`DropHighlightView`).
    case dropHighlight
    /// The sidebar's show and hide, with the window's views beside it (`SidebarContainerView.apply()`).
    case sidebarSlide
}
