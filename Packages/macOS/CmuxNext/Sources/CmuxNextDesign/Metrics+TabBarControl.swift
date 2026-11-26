public import CoreGraphics

/// The tab bar's controls, one shape: the + (and its ⌄), the pane's ⋮ and its other tab-row tools are one square
/// ``tabBarControlSide`` across, and every one of them rounds as a tab pill does (Lawrence 2026-11-20, a shot of the
/// `+ ⌄` beside the pane's ⋮: "roundness of this button needs to always be same as roundness of tabs and size of plus
/// button must be same as size of these buttons").
public extension Metrics {
    /// The side of every tab-row and browser-toolbar button's square: a tab's height (``tabHeight``), so it follows the
    /// density and the sidebar's row size as the tabs do. The +, the pane's ⋮, Exit Zoom and pinned tools are that
    /// square; the split look's ⌄ is that tall beside the +; the omnibar row's buttons (its ⋮ among them) take it too.
    ///
    /// Lawrence 2026-11-23: "all buttons need to have same derived size, which is same height as the tabs (which
    /// derives from density level) and width == height". Before, this was the top row's button side
    /// (``TopRowSpacing/buttonSide``, the sidebar header's height: 22 to 26 pt), shorter than the 24 to 36 pt tabs.
    static var tabBarControlSide: CGFloat { tabHeight }

    /// The corner of a tab-bar control of `size`: the tab pill's (``tabCornerRadius``), at most half the control's
    /// shorter side, so it reads as the tabs beside it at every density and never rounds past a circle.
    ///
    /// - Parameter size: The control's (or its fill's) size; defaults to the ``tabBarControlSide`` square.
    /// - Returns: The radius its fill rounds by.
    static func tabBarControlCornerRadius(fitting size: CGSize? = nil) -> CGFloat {
        let side = tabBarControlSide
        return corners.radius(fitting: size ?? CGSize(width: side, height: side), radius: tabCornerRadius)
    }
}
