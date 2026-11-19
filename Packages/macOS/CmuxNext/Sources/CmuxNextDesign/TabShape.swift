public import CoreGraphics

/// `appearance.tabShape`: the shape of the selected tab in every tab bar and of the selected row in the sidebar, one
/// look for both. Leo, 2026-11-18: "the blockiness of tabs both horizontal the the vertical ones in the sidebar should
/// be customized/customizable too. like the "gooey" is each tab looking like it's morphing into the visible pane. the
/// two tone thing."
///
/// - `block` (the default): today's tabs and rows, unchanged: a rounded rectangle at the tab's corner radius
///   (``Metrics/tabCornerRadius``), a folder tab into the content under Subtle Tone.
/// - `rounded`: the selected tab and the sidebar's row fills are capsules (their corner half the tab's height) and the
///   selected tab stays a capsule on the strip under every tone, never a folder into the content.
/// - `gooey`: the selected tab and the selected sidebar row share the content's fill and run into the content card,
///   meeting it through concave fillets (``CornerFlush/goo``), so tab and pane read as one shape. Two tones: the strip's
///   and the pane's, so gooey shades the title area with Subtle Tone's share even under One Color
///   (``Metrics/titleAreaShadeScale``). It draws on the flush corner's frame (the default window style, tabs on top);
///   compact density keeps the pill there, as for every flush look.
///
/// The switch is live: every strip's metrics, the window's chrome (`WindowRootView.observeMainPane` through
/// ``Metrics/chromeShapeKey``) and the sidebar's rows follow in one pass, and a selection change moves the flare with
/// the selection in that same pass (no animation, no layout change: only fills and the shade's hole change).
public nonisolated enum TabShape: String, Sendable, CaseIterable, Codable {
    case block
    case rounded
    case gooey

    /// Whether the selected tab may run into the content card as a folder tab (the chrome decides when it does).
    public var runsIntoCard: Bool { self != .rounded }

    /// Whether the shape needs the two tones (the strip's and the pane's) to read at all.
    public var needsTone: Bool { self == .gooey }

    /// The corner of a fill `height` tall that a tab or row whose own corner is `radius` draws: half the height capped
    /// at half the tab's height under `rounded` (a capsule on one line, a tall row's ends as round as a tab's), else
    /// `radius`.
    public func fillCornerRadius(_ radius: CGFloat, height: CGFloat, tabHeight: CGFloat) -> CGFloat {
        guard self == .rounded, radius > 0 else { return radius }
        return max(radius, min(height, tabHeight) / 2)
    }
}
