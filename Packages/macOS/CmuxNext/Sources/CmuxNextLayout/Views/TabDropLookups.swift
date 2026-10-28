import CoreGraphics

/// One in-process drag's drop-target lookups on one layout (`LayoutRootView.updateTabDrag`'s
/// `lookups`). The App's drop target keeps one for the length of a drag and hands it to every
/// update; the counts are what the drag's work budget test reads (TabDragWorkTests).
public final class TabDropLookups {
    /// `ScreenContentView.dropTarget` evaluations.
    public internal(set) var targets = 0
    /// Full `ScreenGeometry.compute` passes: a columns screen's split room check and an edge's
    /// final-layout preview.
    public internal(set) var geometryComputes = 0
    /// `navigationFrames` and pane chrome band maps built.
    public internal(set) var frameMaps = 0

    public init() {}
}
