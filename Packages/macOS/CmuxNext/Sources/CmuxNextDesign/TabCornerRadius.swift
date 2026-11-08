public import CoreGraphics
public import Foundation

/// The one tab shape: every tab pill, the strip's + and a tab's hover card share
/// `tabCornerRadius`, concentric with the card the strip sits in, in every window style
/// (Lawrence 2026-10-29: "i dont think both the tab roundness matches the bg pane roundness";
/// 2026-11-04: one radius setting for tabs and panes, inner = outer minus padding).
///
/// A shape nested in a rounded corner reads as part of it only when it is concentric: its
/// radius is the outer radius less the gap between the two. A top-row pane's first pill sits
/// `tabStripCardInset` points in from the card's top and leading edges (the same gap on both,
/// `PaneChromeMetrics`), so its radius is the card's less that inset.
extension Metrics {
    /// This Mac's titled-window corner radius (``standardWindowCornerRadius(macOSMajor:)``): what
    /// `NSWindow.frameCornerRadius` returns when AppKit reports none, and the window corner the
    /// curved main pane, and so the tabs, are concentric with. A fullscreen window has square
    /// corners; the main pane and the tabs keep the windowed radius there, so a fullscreen toggle
    /// never reshapes every tab.
    public static var standardWindowCornerRadius: CGFloat {
        standardWindowCornerRadius(macOSMajor: runningMacOSMajor)
    }

    /// The running macOS major version, read once (it cannot change while the app runs).
    private static let runningMacOSMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion

    /// The corner radius of a titled window on macOS `macOSMajor`, as AppKit draws it: 16 pt from
    /// macOS 26 on (measured on 27: titled, full-size content and every toolbar style alike),
    /// 10 pt on macOS 11 through 15. Lawrence 2026-11-07: "we are not concentric with macos window
    /// ... make it all concentric with macos windows by default".
    public static func standardWindowCornerRadius(macOSMajor: Int) -> CGFloat {
        16
    }

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
    /// cell) plus the pill's inset in the strip (`layout.cornerPadding` when set), on the 2x
    /// pixel grid.
    public static var tabStripCardInset: CGFloat { PaneChromeMetrics.current.tabGap(scale: 2) }

    /// Corner radius of every tab pill, the strip's + and a tab's hover card: concentric with
    /// the rounded card the strip sits in (``tabStripCardRadius``, else the one outer
    /// ``cornerRadius`` where the strip's corner is square or outlined), that radius less
    /// ``tabStripCardInset`` (``ConcentricCorners``), at most half the tab's height. The
    /// defaults (8 pt outer, the omnibar's, 2 pt gap) make a 6 pt tab. The sidebar's workspace
    /// rows read this radius too, so a row is as round as a tab.
    public static var tabCornerRadius: CGFloat {
        let corners = Metrics.corners
        let outer = tabStripCardRadius ?? corners.outer
        return corners.radius(fitting: CGSize(width: tabHeight, height: tabHeight),
                              radius: corners.nested(in: outer, inset: tabStripCardInset))
    }
}
