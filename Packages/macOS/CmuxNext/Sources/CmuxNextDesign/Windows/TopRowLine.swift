public import AppKit
public import CmuxNextDesignTokens

/// The one horizontal line of a minimal window's top row (Leo 2026-11-07: "align the top bit of the
/// sidebar with the tabs/vice versa"): the traffic lights, the toolbar band (sidebar toggle, Back,
/// Forward), the sidebar's + and the top row's tab pills all center on it, at every density.
/// Debug Settings `chrome.topRowLine` keeps the variants measured for the change:
public nonisolated enum TopRowLineLook: String, Sendable, CaseIterable, Hashable, TunableChoice {
    /// The default: everything centers on the traffic lights' line, the one line the window cannot
    /// move; the top row's pills move inside their strip to reach it.
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
        case .lights: "Traffic lights' line (default)"
        case .tabs: "The tabs' line"
        case .titlebar: "Middle of the titlebar row"
        case .off: "Off (pills on their strip's padding)"
        }
    }

    public static let tunable = Tunable<TopRowLineLook>.choice(
        "chrome.topRowLine", .sidebar, "Top row line",
        help: "The line the traffic lights, the toolbar band, the sidebar's + and the top row's tabs share (Leo 2026-11-07).",
        default: .lights, code: "TopRowLineLook.tunable")
}

/// The top row's line, from the window's top edge, and where a top-row strip puts its pills on it.
/// Pure, so `TopRowAlignmentTests` holds the lines with fixed numbers at every density.
public nonisolated struct TopRowLine: Equatable, Sendable {
    /// The line's distance from the window's top edge.
    public var centerY: CGFloat

    public init(centerY: CGFloat) { self.centerY = centerY }

    /// The nearest a top-row pill comes to the window's top edge: one point, so the pill's top
    /// corners stay inside the window at the roomiest densities. The pill never leaves its strip
    /// either (the strip masks its tabs to its bounds), whatever this allows.
    public static let pillMinTopGap: CGFloat = 1

    /// The line for `look`: the lights' center (`lights`, `off`), the pill center the top row's tabs
    /// keep on their own padding (`tabs`, ``tabsCenterY(_:scale:)``), or the titlebar row's middle
    /// (`titlebar`).
    public static func resolve(_ look: TopRowLineLook, lightsCenterY: CGFloat, tabsCenterY: CGFloat,
                               titlebarHeight: CGFloat) -> TopRowLine {
        switch look {
        case .lights, .off: TopRowLine(centerY: lightsCenterY)
        case .tabs: TopRowLine(centerY: tabsCenterY)
        case .titlebar: TopRowLine(centerY: titlebarHeight / 2)
        }
    }

    /// The pill center, from the cell's top (the window's top for the top row), where the tabs sit on
    /// their own padding: the pane padding above the strip, the pill's inset in it, half the pill.
    /// The `tabs` variant puts the card's top at 0 with it, so the strip's pills keep exactly this.
    public static func tabsCenterY(_ metrics: PaneChromeMetrics, scale: CGFloat) -> CGFloat {
        metrics.tabGap(scale: scale) + metrics.tabHeight / 2
    }

    /// The pill's top inside a top-row strip whose top edge is `stripTop` below the window's top, so
    /// the pill's center sits on the line: never above the strip's own top (the strip clips its tabs
    /// to its bounds), never nearer the window's top than ``pillMinTopGap``, and never past the
    /// strip's bottom, on `scale`'s pixel grid. A strip that starts at or below the line (a large
    /// pane padding, floating panes) keeps its pills at its top. Staying inside the strip wins over
    /// the window-top gap: a pill as tall as its strip (flat chrome, no corner padding) sits at 0.
    public func pillTop(stripTop: CGFloat, stripHeight: CGFloat, tabHeight: CGFloat, scale: CGFloat) -> CGFloat {
        let want = centerY - tabHeight / 2 - stripTop
        let high = max(0, stripHeight - tabHeight)
        let low = min(max(0, Self.pillMinTopGap - stripTop), high)
        let s = max(scale, 1)
        return (min(max(want, low), high) * s).rounded() / s
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
    public static func topRowLine(in window: NSWindow, look: TopRowLineLook = TopRowLineLook.tunable.value) -> TopRowLine? {
        let settings = DesignSettings.shared
        guard settings.titlebar == .minimal, settings.tabBarPosition == .top,
              let lights = trafficLightsFrame(in: window), let content = window.contentView else { return nil }
        let lightsCenter = content.bounds.maxY - content.convert(lights, from: nil).midY
        return TopRowLine.resolve(look, lightsCenterY: lightsCenter,
                                  tabsCenterY: TopRowLine.tabsCenterY(.current, scale: window.backingScaleFactor),
                                  titlebarHeight: Metrics.titlebarHeight)
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
