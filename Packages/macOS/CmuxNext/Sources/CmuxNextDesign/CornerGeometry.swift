public import CoreGraphics
public import CmuxNextDesignTokens
public import QuartzCore

/// One shape language for the sidebar and the horizontal tabs (Debug Settings,
/// `chrome.cornerGeometry`; Leo 2026-11-05: "you can't mix straight with curved").
///
/// Today's default (`off`) puts 8 pt tab pills inside a 10/11 pt main pane whose curve only
/// shows as clipping, next to a sidebar whose edge is one straight hairline. Each other value
/// is a comparison variant that draws the sidebar, the tab strip and the content card from
/// one radius scale (``CornerGeometry/Scale``, design/grid.md: radii are 4, 6, 8, 12 or 16),
/// so every curve on screen is a step of the same scale and every nested pair is concentric.
/// Compact density keeps today's geometry in every variant (Lawrence's ultra compact mode).
/// The default is `off`, which changes nothing.
public nonisolated enum CornerGeometry: String, Sendable, CaseIterable, TunableChoice {
    /// Today's geometry.
    case off
    /// Tab pills are square on their leading edge, the side that faces the sidebar's straight
    /// edge, and keep the scale's tab radius on the trailing edge.
    case tabsSquareLeading = "tabs-square-leading"
    /// Square tabs and a square + beside straight sidebar: every edge in the corner is straight.
    case tabsSquare = "tabs-square"
    /// Arc's frame: the content area below the top tab strip is one inset rounded card; the
    /// sidebar and the tab strip are the frame around it, on one shaded color.
    case framedCard = "framed-card"
    /// The sidebar is a rounded card matching the content card (same radius, same gap), both on
    /// the shaded frame: two curved cards, no straight hairline.
    case matchedSidebar = "matched-sidebar"

    public var tunableTitle: String {
        switch self {
        case .off: "Off (today)"
        case .tabsSquareLeading: "Tabs square on the leading edge"
        case .tabsSquare: "Square tabs"
        case .framedCard: "Framed card (sidebar and tabs frame the content)"
        case .matchedSidebar: "Matched sidebar card"
        }
    }

    public static let tunable = Tunable<CornerGeometry>.choice(
        "chrome.cornerGeometry", .sidebar, "Corner geometry",
        help: "Comparison variants where the sidebar and the horizontal tabs share one shape language and one radius scale (4, 8, 12, 16). Compact density keeps today's shapes. Off: today's.",
        default: .off, code: "CornerGeometry.tunable")

    /// The variant in effect: the Debug Settings value, except at compact density, which keeps
    /// today's geometry (`off`).
    @MainActor public static var current: CornerGeometry {
        let value = tunable.value
        return Metrics.density == .compact ? .off : value
    }

    /// The one radius scale every variant reads (design/grid.md "Radii are 4, 6, 8, 12 or 16"),
    /// with its concentric steps: the window's 16 pt corner, the content and sidebar cards 4 pt
    /// inside it (12), a tab pill 4 pt inside a card (8) and a fill inside a pill (4).
    public struct Scale: Sendable, Equatable {
        /// The macOS 26 window corner (``Metrics/standardWindowCornerRadius``).
        public var window: CGFloat = 16
        /// The gap between the window edge, the cards and each other: one grid step.
        public var gap: CGFloat = LayoutGrid.base
        /// A card: the content area, and the sidebar under `matched-sidebar`.
        public var card: CGFloat { window - gap }
        /// A tab pill and the strip's +, nested a gap inside a card.
        public var tab: CGFloat { card - gap }
        /// A fill inside a pill (close button hover, badges).
        public var fill: CGFloat { tab - gap }

        public init() {}
    }

    /// The scale (one per app; a UI scale multiplies it through ``Metrics/scale(_:)``).
    public static var scale: Scale { Scale() }

    /// Whether this variant draws the content card and the shaded frame around it.
    public var drawsFrame: Bool { self == .framedCard || self == .matchedSidebar }

    /// The tab pill radius under this variant; nil keeps ``Metrics/tabCornerRadius``.
    @MainActor public var tabRadius: CGFloat? {
        switch self {
        case .off: nil
        case .tabsSquare: 0
        case .tabsSquareLeading, .framedCard, .matchedSidebar: Metrics.scale(Self.scale.tab)
        }
    }

    /// The pill corners that are rounded (Core Animation's corner mask): every corner, or only
    /// the trailing (maximum x) ones under `tabs-square-leading`, the side away from the sidebar.
    public var tabRoundedCorners: CACornerMask {
        let all: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        return self == .tabsSquareLeading ? [.layerMaxXMinYCorner, .layerMaxXMaxYCorner] : all
    }

    /// A pill's path with `radius` on the corners `rounded` names and square ones elsewhere
    /// (a drawn copy of a layer with that radius and corner mask; only the x side matters).
    public static func pillPath(_ rect: CGRect, radius: CGFloat, rounded: CACornerMask) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let leading = rounded.contains(.layerMinXMinYCorner) ? r : 0
        let trailing = rounded.contains(.layerMaxXMinYCorner) ? r : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + leading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - trailing, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: trailing)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: trailing)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: leading)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: leading)
        path.closeSubpath()
        return path
    }

    /// The content card's radius when this variant draws the frame; nil keeps the main pane's.
    @MainActor public var cardRadius: CGFloat? { drawsFrame ? Metrics.scale(Self.scale.card) : nil }

    /// The frame's gap (window edge, sidebar, titlebar) when this variant draws the frame.
    @MainActor public var frameGap: CGFloat? { drawsFrame ? Metrics.scale(Self.scale.gap) : nil }

    /// The frame's shade (black's alpha over the chrome) when this variant draws the frame:
    /// the separate-surface shade of the main pane tunables, so the cards read on any theme.
    @MainActor public func frameShade(isDark: Bool) -> CGFloat? {
        guard drawsFrame else { return nil }
        let tunable = isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight
        return CGFloat(tunable.value)
    }

    /// The shade's holes under this variant: the content `card` (the content host, or under
    /// `framed-card` its part below the top row's tab strip, so the strip sits on the frame
    /// with the sidebar and the card's top corners curve under the tabs, as Arc's frame does),
    /// and under `matched-sidebar` the sidebar's own card: the sidebar inset by the frame's gap
    /// from the window's edges (its inner side is already the gap from the content card), with
    /// the content card's `radius`. Rects are in the (unflipped) window root's coordinates.
    @MainActor
    public func shadeHoles(content: CGRect, radius: CGFloat, in bounds: CGRect, page: Bool, sidebar: CGRect?,
                           sidebarOnLeft: Bool) -> (card: CGRect, cutouts: [PaneCard]) {
        var card = content
        guard !page else { return (card, []) }
        if self == .framedCard, DesignSettings.shared.tabBarPosition != .bottom {
            card.size.height = max(0, card.height - (Metrics.stripTopOutset + Metrics.tabStripHeight)) // the top is maxY
        }
        guard self == .matchedSidebar, let sidebar, sidebar.width > 0, let gap = frameGap else { return (card, []) }
        let rect = CGRect(x: sidebarOnLeft ? sidebar.minX + gap : sidebar.minX, y: bounds.minY + gap,
                          width: sidebar.width - gap, height: bounds.height - 2 * gap)
        return (card, [PaneCard(rect: rect, radius: radius)])
    }
}

extension Metrics {
    /// What reshapes the main pane's chrome beside its numbers (`WindowRootView.observeMainPane`):
    /// floating panes and the corner geometry variant.
    public static var chromeShapeKey: CGFloat {
        CGFloat((floatingPanes ? 1 : 0) + 2 * (CornerGeometry.allCases.firstIndex(of: CornerGeometry.current) ?? 0))
    }
}
