public import CoreGraphics

/// Every button rounds as a tab (Lawrence 2026-11-12: "roundness of all buttons should match roundness of
/// tabs/workspaces").
public extension Metrics {
    /// Corner radius of every button: the tab pill's (``tabCornerRadius``), which sidebar workspace rows
    /// share, so a toolbar button, a dialog button, a chip and a tab all round alike at every density and
    /// corner setting. Pages read the same value as `--cmux-button-radius` (`var(--ds-radius-control)`).
    static var buttonCornerRadius: CGFloat { tabCornerRadius }

    /// The button corner on a button of `size`: ``buttonCornerRadius``, at most half its shorter side, so
    /// a small round control stays a circle instead of rounding past its own height.
    static func buttonCornerRadius(fitting size: CGSize) -> CGFloat {
        corners.radius(fitting: size, radius: buttonCornerRadius)
    }

    /// The corner of a small button `side` points tall, such as a tab's close: Helium's roundness, 8 on 28 (its
    /// location bar and buttons; Lucas 2026-11-14 measured the close's reference at 8 px on 28), at that size on the
    /// half-point grid, so it rounds as the chrome's other buttons do at every density, never past a circle.
    /// A corner radius the person set (``cornerRadiusIsSet``) keeps every button on it instead, as the concentric chain
    /// from that radius needs.
    static func buttonCornerRadius(proportionalTo side: CGFloat) -> CGFloat {
        if cornerRadiusIsSet { return min(buttonCornerRadius, side / 2) }
        return min(((side * 8 / 28) * 2).rounded() / 2, side / 2)
    }

    /// The corner of a button nested `inset` points inside a rounded shape whose corner is the button corner
    /// (a segmented control's segment, a chip in a pill): ``buttonCornerRadius`` less the inset, the
    /// concentric rule (inner = outer - inset), so the gap between the two corners stays even.
    static func buttonCornerRadius(nestedIn outer: CGFloat? = nil, inset: CGFloat) -> CGFloat {
        corners.nested(in: outer ?? buttonCornerRadius, inset: inset)
    }
}
