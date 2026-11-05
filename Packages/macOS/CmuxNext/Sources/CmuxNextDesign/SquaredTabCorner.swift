public import AppKit
public import CmuxNextDesignTokens

/// Thunderdome r2 B, "squared" (Debug Settings, `chrome.squaredTab`; Leo 2026-11-05: "the tab at its
/// left, when it's at the leftmost on that left area, is just square").
///
/// The top row is the top bar of the whole window: one surface across the sidebar's header and the
/// tab row, with the sidebar's + on the tabs' center line. The tab strip that starts at the sidebar's
/// edge starts its first tab on that edge, square on the side that touches it, so the edge's straight
/// line runs straight into the tab and nothing curves away from it. Every other tab keeps its rounding.
/// Off (the default) changes nothing.
public nonisolated enum SquaredTabCorner: String, Sendable, CaseIterable, TunableChoice {
    /// Today's geometry.
    case off
    /// Today's flat window: the sidebar's edge line starts under the top row and runs into the
    /// first tab's square side.
    case flat
    /// The content is a rounded card under the tab row, framed by one surface: the top row and the
    /// sidebar ("a glass frame, another glass frame"). The first tab's square side sits on the
    /// card's leading edge.
    case framed
    /// As `framed`, and the sidebar is a card of its own matching the content card: same radius,
    /// same gap, both under the one top row.
    case matched

    public var tunableTitle: String {
        switch self {
        case .off: "Off (today)"
        case .flat: "Flat: the edge line runs into a square first tab"
        case .framed: "Framed: a content card under one top row"
        case .matched: "Matched: sidebar and content cards under one top row"
        }
    }

    public static let tunable = Tunable<SquaredTabCorner>.choice(
        "chrome.squaredTab", .sidebar, "Squared first tab (r2 B)",
        help: "The top row is one surface across the sidebar and the tabs, the + sits on the tabs' line, and the first tab is square where it meets the sidebar's edge. Framed and matched draw the content (and the sidebar) as cards under that row. Off: today's.",
        default: .off, code: "SquaredTabCorner.tunable")

    /// The value in effect.
    @MainActor public static var current: SquaredTabCorner { tunable.value }

    /// A number per look, for observation streams of numbers.
    public var observationKey: CGFloat { CGFloat(Self.allCases.firstIndex(of: self) ?? 0) }

    /// Whether this look draws the content card on a shaded frame.
    public var drawsFrame: Bool { self == .framed || self == .matched }

    /// The frame's gap (window edge, sidebar, the row above the card): one grid step.
    @MainActor public static var frameGap: CGFloat { Metrics.scale(LayoutGrid.base) }

    /// The cards' radius: the 16 pt window corner less the gap, so card and window are concentric.
    @MainActor public static var cardRadius: CGFloat { Metrics.scale(Metrics.standardWindowCornerRadius) - frameGap }

    /// The frame's shade (black's alpha over the chrome): the separate-surface shade of the main
    /// pane tunables, so the cards read on any theme.
    @MainActor public static func frameShade(isDark: Bool) -> CGFloat {
        CGFloat((isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight).value)
    }

    /// The shade's holes (the content host alone when the look draws no frame or a page fills the window): the content card (the content host below its top row's tab strip, so the
    /// strip sits on the frame with the sidebar's header), and under `matched` the sidebar's card,
    /// from the same top as the content card to the window's bottom less the gap, inset by the gap
    /// from the window's side. Rects are in the (unflipped) window root's coordinates.
    @MainActor
    public func shadeHoles(content: CGRect, in bounds: CGRect, sidebar: CGRect?, sidebarOnLeft: Bool, page: Bool) -> (card: CGRect, cutouts: [PaneCard]) {
        var card = content
        guard drawsFrame, !page else { return (card, []) }
        if DesignSettings.shared.tabBarPosition != .bottom {
            card.size.height = max(0, card.height - (Metrics.stripTopOutset + Metrics.tabStripHeight)) // the top is maxY
        }
        guard self == .matched, let sidebar, sidebar.width > 1 else { return (card, []) }
        let gap = Self.frameGap
        let minX = sidebarOnLeft ? max(bounds.minX + gap, sidebar.minX + gap) : content.maxX + gap
        let maxX = sidebarOnLeft ? content.minX - gap : min(bounds.maxX - gap, sidebar.maxX - gap)
        let rect = CGRect(x: minX, y: bounds.minY + gap, width: max(0, maxX - minX), height: max(0, card.maxY - bounds.minY - gap))
        return (card, [PaneCard(rect: rect, radius: Self.cardRadius)])
    }
}

/// The view the workspace content sits in (the main pane's card). A tab strip inside it whose leading
/// edge is the card's leading edge, with the sidebar beside that edge, starts its first tab there,
/// square on that side (`SquaredTabCorner`).
@MainActor
public protocol LeadingTabEdgeAnchor: NSView {}
