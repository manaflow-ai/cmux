public import CoreGraphics

/// Scroll areas in a screen's geometry (plans/cmux-next/scroll-areas-DESIGN.md).
nonisolated extension ScreenGeometry {
    /// `pane`'s frame for directional focus (K1): inside a scroll area, mapped into the area's
    /// window in proportion (``ScrollAreaGeometry/navigationRect(_:)``); else its frame.
    public func navigationRect(of pane: PaneID) -> CGRect? {
        panes[pane]
    }
}
