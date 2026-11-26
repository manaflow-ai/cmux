public import CoreGraphics

/// The tab bar's controls, one shape: the + (and its ⌄), the pane's ⋮ and its other tab-row tools are one square
/// ``tabBarControlSide`` across, and every one of them rounds as a tab pill does (Lawrence 2026-11-20, a shot of the
/// `+ ⌄` beside the pane's ⋮: "roundness of this button needs to always be same as roundness of tabs and size of plus
/// button must be same as size of these buttons").
public extension Metrics {
    /// The side of every tab-bar control's square: the chrome's one button size (``TopRowSpacing/buttonSide``,
    /// ``TitlebarBandButton/side``), at every density. The + is that square, as the ⋮ is; the split look's ⌄ is that
    /// tall beside it.
    static var tabBarControlSide: CGFloat { TopRowSpacing.buttonSide }

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
