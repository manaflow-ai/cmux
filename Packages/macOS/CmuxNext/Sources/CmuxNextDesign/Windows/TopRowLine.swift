public import AppKit
public import CmuxNextDesignTokens

/// The one horizontal line of a minimal window's top row (Leo 2026-11-07: "align the top bit of the
/// sidebar with the tabs/vice versa"): the traffic lights, the toolbar band (sidebar toggle, Back,
/// Forward), the sidebar's + and the top row's tab pills all center on it, at every density.
/// Debug Settings `chrome.topRowLine` keeps the variants measured for the change:
public nonisolated enum TopRowLineLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default: the main pane's card keeps the gutter at the top as at the sides, so its corner
    /// is concentric with the window's (Lawrence 2026-11-07: "concentricity padding on top of tabbar
    /// is bad", "make it all concentric with macos windows by default"). The top row's pills sit in
    /// their strip as in every other row, and the toolbar band, the sidebar's + and the pane's
    /// buttons center on the pills' line; only the traffic lights, which macOS draws, keep their own.
    case concentric
    /// Everything centers on the traffic lights' line, the one line the window cannot
    /// move; the main pane's card moves down to bring the top row's pills to it, and the pills keep
    /// equal gaps above and below them (#38054). Where the card cannot reach it, the line is the pills'.
    case lights
    /// The controls follow the tabs: the band and the + center on the line the top-row pills keep on
    /// their own padding (the pane padding above the strip plus the pill's inset, `PaneChromeMetrics`;
    /// the lights stay where macOS draws them).
    case tabs
    /// One titlebar height: the band, the + and the pills center on the middle of the
    /// `titlebarHeight` row (the lights stay where macOS draws them).
    case titlebar
    /// The look before 2026-11-07: the band and the + on the lights' line, the pills where their
    /// strip's own padding puts them.
    case off

    public var tunableTitle: String {
        switch self {
        case .concentric: "Even inset, concentric with the window (default)"
        case .lights: "Traffic lights' line"
        case .tabs: "The tabs' line"
        case .titlebar: "Middle of the titlebar row"
        case .off: "Off (pills on their strip's padding)"
        }
    }

    public static let tunable = Tunable<TopRowLineLook>.choice(
        "chrome.topRowLine", .sidebar, "Top row line",
        help: "The line the traffic lights, the toolbar band, the sidebar's + and the top row's tabs share (Leo 2026-11-07).",
        default: .concentric, code: "TopRowLineLook.tunable")
}

/// The top row's line, from the window's top edge, and where a top-row strip puts its pills on it.
/// Pure, so `TopRowAlignmentTests` holds the lines with fixed numbers at every density.
public nonisolated struct TopRowLine: Equatable, Sendable {
    /// The line's distance from the window's top edge.
    public var centerY: CGFloat

    public init(centerY: CGFloat) { self.centerY = centerY }

    /// The line for `look`: the lights' center (`lights`, `off`), the pill center the top row's tabs
    /// keep on their own padding (`tabs`, ``tabsCenterY(_:scale:)``), that center below a card
    /// `concentricCardTop` down (`concentric`, the gutter), or the titlebar row's middle (`titlebar`).
    public static func resolve(_ look: TopRowLineLook, lightsCenterY: CGFloat, tabsCenterY: CGFloat,
                               titlebarHeight: CGFloat, concentricCardTop: CGFloat = 0) -> TopRowLine {
        switch look {
        case .lights, .off: TopRowLine(centerY: lightsCenterY)
        case .tabs: TopRowLine(centerY: tabsCenterY)
        case .concentric: TopRowLine(centerY: concentricCardTop + tabsCenterY)
        case .titlebar: TopRowLine(centerY: titlebarHeight / 2)
        }
    }

    /// The pill center, from the cell's top (the window's top for the top row), where the tabs sit on
    /// their own padding: the pane padding above the strip, the pill's inset in it, half the pill.
    /// The `tabs` variant puts the card's top at 0 with it, so the strip's pills keep exactly this.
    public static func tabsCenterY(_ metrics: PaneChromeMetrics, scale: CGFloat) -> CGFloat {
        metrics.tabGap(scale: scale) + metrics.tabHeight / 2
    }

    /// The line the top row's pills reach with the card's top `cardTop` down: their center
    /// (`PaneChromeMetrics.topRowPillCenter`). The pills keep equal gaps above and below and only the
    /// card moves to reach a line (#38054), so a line the card cannot reach (Comfortable and
    /// Spacious, whose pills center below the lights' line with the card at the window's top) gives
    /// way to the pills': the toolbar band, the sidebar's + and the pane's buttons stay on the tabs'
    /// line, and only the traffic lights, which macOS draws, keep their own.
    public func reached(by metrics: PaneChromeMetrics, cardTop: CGFloat, scale: CGFloat) -> TopRowLine {
        TopRowLine(centerY: metrics.topRowPillCenter(cardTop: cardTop, scale: scale))
    }

    /// A control `side` tall centered on the line, its top from the window's top, on the pixel grid.
    public func controlTop(side: CGFloat, scale: CGFloat) -> CGFloat {
        let s = max(scale, 1)
        return ((centerY - side / 2) * s).rounded() / s
    }
}

@MainActor
extension WindowTitlebar {
    /// The top row's line in `window`, from its top edge, under a minimal titlebar with the traffic
    /// lights showing and the tab bars on top; nil otherwise (the callers keep their own row middle).
    /// The line is where the top row's pills come to rest (``TopRowLine/reached(by:cardTop:scale:)``):
    /// the variant's line when the card can move to it, else the pills' own center. `off` keeps the
    /// lights' line (the look before 2026-11-07); floating panes report the pills' center in their
    /// own cards, which sit the gutter and a pane padding down.
    public static func topRowLine(in window: NSWindow, look: TopRowLineLook = TopRowLineLook.tunable.value) -> TopRowLine? {
        guard let target = targetTopRowLine(in: window, look: look) else { return nil }
        guard look != .off, look != .concentric else { return target }
        let scale = window.backingScaleFactor
        let row = topRowMetrics(scale: scale)
        if Metrics.floatingPanes {
            let stripTop = Metrics.mainPaneGutter + PaneChromeMetrics.snap(Metrics.panePadding, scale)
            return TopRowLine(centerY: stripTop + row.pillTop(scale: scale) + row.tabHeight / 2)
        }
        let card = topRowCardTop(centeringPillOn: target.centerY, gutter: Metrics.mainPaneGutter, in: window, look: look)
        return target.reached(by: row, cardTop: card, scale: scale)
    }

    /// Whether the top row's strips center their pills between the window's top edge and the divider
    /// under the row (#38054): a minimal window with the tab bars on top and the lights showing, a
    /// line variant other than `off`, and no floating panes (each of those pills centers in its own card).
    public static func topRowEvensPillGaps(in window: NSWindow) -> Bool {
        let look = TopRowLineLook.tunable.value
        return look != .off && look != .concentric && !Metrics.floatingPanes && targetTopRowLine(in: window, look: look) != nil
    }

    /// The variant's line before the card's limits (``topRowLine(in:look:)``): what the card's top aims for.
    static func targetTopRowLine(in window: NSWindow, look: TopRowLineLook = TopRowLineLook.tunable.value) -> TopRowLine? {
        let settings = DesignSettings.shared
        guard settings.titlebar == .minimal, settings.tabBarPosition == .top,
              let lights = trafficLightsFrame(in: window), let content = window.contentView else { return nil }
        let lightsCenter = content.bounds.maxY - content.convert(lights, from: nil).midY
        return TopRowLine.resolve(look, lightsCenterY: lightsCenter,
                                  tabsCenterY: TopRowLine.tabsCenterY(.current, scale: window.backingScaleFactor),
                                  titlebarHeight: Metrics.titlebarHeight,
                                  concentricCardTop: Metrics.floatingPanes ? Metrics.mainPaneGutter : Metrics.windowEdgeInset(Metrics.mainPaneGutter, in: window))
    }

    /// The live pane chrome with the strip as tall as panes lay it out (`resolvedStripHeight`, a device
    /// pixel under the token when the room around the pill does not split evenly).
    static func topRowMetrics(scale: CGFloat) -> PaneChromeMetrics {
        let current = PaneChromeMetrics.current
        return PaneChromeMetrics(stripHeight: current.resolvedStripHeight(scale: scale), tabHeight: current.tabHeight,
                                 panePadding: current.panePadding, outlinedContent: current.outlinedContent)
    }

    /// The main pane card's top under a minimal titlebar with the top row's pills aiming for
    /// `centerY`: as far down as centers them on it with equal gaps (`PaneChromeMetrics.cardTop`),
    /// never more than `gutter`, never over the window's lit rim; floating panes keep the gutter, and
    /// `off` keeps the strip's own centering (`PaneChromeMetrics.cardTopKeepingStripCentering`).
    public static func topRowCardTop(centeringPillOn centerY: CGFloat, gutter: CGFloat, in window: NSWindow,
                                     look: TopRowLineLook = TopRowLineLook.tunable.value) -> CGFloat {
        guard !Metrics.floatingPanes else { return gutter }
        // Concentric: the gutter on top as at the sides, so the card's corner shares the window's center.
        guard look != .concentric else { return Metrics.windowEdgeInset(gutter, in: window) }
        let scale = window.backingScaleFactor
        guard look != .off else {
            return Metrics.windowEdgeInset(min(gutter, PaneChromeMetrics.current.cardTopKeepingStripCentering(centeringPillOn: centerY, scale: scale)), in: window)
        }
        let row = topRowMetrics(scale: scale), floor = Metrics.windowEdgeInset(0, in: window)
        let card = max(min(gutter, row.cardTop(centeringPillOn: centerY, scale: scale)), floor)
        return row.evenSplitCardTop(card, within: floor...max(gutter, floor), scale: scale)
    }

    /// Lays out every view of `window` again: the sidebar (every window has one) calls it when Debug Settings picks
    /// another line, since the strips, the toolbar band, the sidebar's + and the card top all read
    /// the line in `layout()`. One walk per change of a Debug setting, never per frame.
    public static func layOutTopRowAgain(in window: NSWindow) {
        func mark(_ view: NSView) {
            view.needsLayout = true
            view.subviews.forEach(mark)
        }
        window.contentView.map(mark)
    }
}
