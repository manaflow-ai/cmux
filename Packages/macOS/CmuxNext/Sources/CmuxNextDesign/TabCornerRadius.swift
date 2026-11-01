public import CoreGraphics

/// The one tab shape: every tab pill, the strip's + and a tab's hover card share
/// `tabCornerRadius`: Helium's 8 pt circular corner (Lawrence 2026-10-31), or concentric with
/// the pane's own card under Floating Panes (Lawrence 2026-10-29: "i dont think both the tab
/// roundness matches the bg pane roundness").
///
/// A shape nested in a rounded corner reads as part of it only when it is concentric: its
/// radius is the outer radius less the gap between the two. A top-row pane's first pill sits
/// `tabStripCardInset` points in from the card's top and leading edges (the same gap on both,
/// `PaneChromeMetrics`), so its radius is the card's less that inset.
extension Metrics {
    /// The macOS 26 titled-window corner radius: what `NSWindow.frameCornerRadius` returns when
    /// AppKit reports none, and the window corner the curved main pane, and so the tabs, are
    /// concentric with. A fullscreen window has square corners and a main pane of
    /// `mainPaneCornerRadius`; the tabs keep the windowed radius there, so a fullscreen toggle
    /// never reshapes every tab.
    public static let standardWindowCornerRadius: CGFloat = 16

    /// The radius of the rounded card whose top-leading corner a top-row pane's tab strip sits
    /// in: the pane's own card under Floating Panes, else the curved main pane's card when no
    /// outline runs under the strip. Nil when that corner is square or outlined (the first pill
    /// then starts on the outline, not inside a curve).
    public static var tabStripCardRadius: CGFloat? {
        if floatingPanes { return paneCornerRadius > 0 ? paneCornerRadius : nil }
        guard mainPaneCurved, paneBorder == .none else { return nil }
        let radius = mainPaneCornerRadius(windowCornerRadius: standardWindowCornerRadius)
        return radius > 0 ? radius : nil
    }

    /// Points from the card's top (and leading) edge to the first tab pill: the pane padding
    /// between the card and the strip (none under Floating Panes, where the card is the padded
    /// cell) plus the pill's inset in the strip, on the 2x pixel grid.
    public static var tabStripCardInset: CGFloat { PaneChromeMetrics.current.tabGap(scale: 2) }

    /// Corner radius of every tab pill, the strip's + and a tab's hover card: Helium's
    /// (``heliumTabCornerRadius``, 8 pt circular; Lawrence 2026-10-31 "match helium roundess"),
    /// at most half the tab's height. Under Floating Panes, whose own card is only 6-8 pt, the
    /// pill stays concentric with that card (its radius less ``tabStripCardInset``, at least
    /// `space2`), so it never pokes out of the corner it sits in.
    public static var tabCornerRadius: CGFloat {
        if floatingPanes, let card = tabStripCardRadius {
            return min(max(space2, card - tabStripCardInset), tabHeight / 2)
        }
        return min(heliumTabCornerRadius, tabHeight / 2)
    }
}
