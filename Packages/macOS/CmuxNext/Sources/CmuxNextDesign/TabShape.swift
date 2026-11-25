public import CoreGraphics

/// `appearance.tabShape`: how blocky the tabs of every tab bar and the rows of the sidebar are, one look for both. Leo,
/// 2026-11-18: "the blockiness of tabs both horizontal the the vertical ones in the sidebar should be
/// customized/customizable too. like the "gooey" is each tab looking like it's morphing into the visible pane. the
/// two tone thing."
///
/// - `block` (the default): today's tabs and rows, unchanged: a rounded rectangle at the tab's corner radius
///   (``Metrics/tabCornerRadius``), the selected tab a folder into the content where the flush corner draws one.
/// - `rounded`: the tabs and the sidebar's row fills are capsules (their corner half the tab's height), and the
///   selected tab stays a capsule on the strip under every `appearance.cornerFlush`, never a folder into the content.
///
/// The gooey look is not a third shape here: it is `appearance.cornerFlush` `flush-goo` (``CornerFlush/goo``), which
/// flares the selected tab into the card and, on a block shape, the selected sidebar row too
/// (``CornerFlush/sidebarRowFlows``), on two tones (``Metrics/titleAreaShadeScale``). One setting per look.
///
/// The switch is live: every strip's metrics, the window's chrome (`WindowRootView.observeMainPane` through
/// ``Metrics/chromeShapeKey``) and the sidebar's rows follow in one pass (no animation, no layout change: only
/// corners and fills change).
public nonisolated enum TabShape: String, Sendable, CaseIterable, Codable {
    case block
    case rounded

    /// Whether the selected tab (and, under goo, the selected sidebar row) may run into the content card as a folder
    /// tab (the chrome decides when it does).
    public var runsIntoCard: Bool { self != .rounded }

    /// The corner of a fill `height` tall that a tab or row whose own corner is `radius` draws: half the height capped
    /// at half the tab's height under `rounded` (a capsule on one line, a tall row's ends as round as a tab's), else
    /// `radius`.
    public func fillCornerRadius(_ radius: CGFloat, height: CGFloat, tabHeight: CGFloat) -> CGFloat {
        guard self == .rounded, radius > 0 else { return radius }
        return max(radius, min(height, tabHeight) / 2)
    }
}
