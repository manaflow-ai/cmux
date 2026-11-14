public import AppKit
public import CmuxNextDesignTokens

/// The flush corner (Debug Settings, `chrome.cornerFlush`; Thunderdome round 2, direction A).
///
/// Leo, 2026-11-05: the top area is the implicit top bar of everything, and the sidebar and the
/// tabs must look like they come from one place. Under a flush value the sidebar, the titlebar
/// row and every tab strip are one frame surface, and the content below the top tab row is one
/// rounded card in it (the "glass frame, another glass frame" he liked in round 1). The selected
/// tab is drawn in the card's own color and runs down into the card, and each strip's first tab
/// starts exactly on its pane's leading edge. So when the first tab of the top-left pane is
/// selected, the card's left edge (the divider beside the sidebar) runs straight up into that
/// tab and curves once, at the tab's top corner: one continuous edge, with no straight line that
/// then curves away and no concave foot that ends in a point. The sidebar's `+`, the window
/// buttons and the tabs share one center line.
///
/// The default is `flush`, no goo, over the stock chrome (``defaultFits``): the selected tab runs into
/// the card with no fillets (Leo, 2026-11-13: "lawrence wanted no goo by default"). `flush-goo`, the
/// folder tab with fillets (Leo, 2026-11-10: "morph it in as like, you know how folder tabs look"),
/// stays one Debug Settings choice away. Compact density keeps the pill under every value. `off`
/// keeps the older pill look.
public nonisolated enum CornerFlush: String, Sendable, CaseIterable, TunableChoice {
    /// The older corner: the selected tab is a gray pill on the frame.
    case off
    /// The card sits one grid step (4 pt) inside the frame on every side.
    case flush
    /// No gap on the sidebar's side: the card's left edge is the sidebar's edge.
    case tight = "flush-tight"
    /// `flush`, and the selected tab meets the card through concave fillets, tangent to both, the
    /// way two drops of water merge (Leo: "the surface tension of water").
    case goo = "flush-goo"

    public var tunableTitle: String {
        switch self {
        case .off: "Off: a gray pill on the frame"
        case .flush: "Flush: the first tab rises from the card's edge"
        case .tight: "Flush, tight: the card meets the sidebar"
        case .goo: "Flush, goo: the selected tab flows into the card"
        }
    }

    public static let tunable = Tunable<CornerFlush>.choice(
        "chrome.cornerFlush", .sidebar, "Corner flush",
        help: "Thunderdome r2 A: the sidebar, the titlebar and the tab strips are one frame around a rounded content card; the selected tab is the card's color and runs into it, and each strip's first tab starts on its pane's edge, so the sidebar's edge rises straight into the first tab. Compact density keeps the pill. The default is flush, no goo, over the stock chrome; goo adds the folder tab's fillets. Off: the gray pill.",
        default: .flush, code: "CornerFlush.tunable")

    /// The value in effect: `off` at compact density, which keeps the pill; else a Debug Settings
    /// value, else the default where the default chrome fits it (``defaultFits``), else `off`.
    @MainActor public static var current: CornerFlush {
        if Metrics.density == .compact { return .off }
        if let chosen = tunable.override { return chosen }
        return defaultFits ? tunable.defaultValue : .off
    }

    /// The default draws only over the stock chrome: the shipped chrome style (`flat`, the
    /// `appearance.chromeStyle` fallback, or `default`), tabs on top and above a page's toolbar (a strip
    /// below it is not the card's top row), no vertical tabs, no
    /// `layout.*` pane padding, corner or border the user set, and no Debug Settings main pane
    /// override. Any of those keeps its own look (floating and blocks panes keep their cards, a set
    /// padding or radius still applies, bottom and vertical tabs have no top strip to run into the card).
    @MainActor static var defaultFits: Bool {
        let design = DesignSettings.shared
        let chrome = design.paneChrome
        guard [.flat, .default].contains(design.chromeStyle), design.tabBarPosition == .top, design.tabBarOrder == .aboveToolbar,
              !design.verticalTabs else { return false }
        guard chrome.padding == nil, chrome.cornerRadius == nil, chrome.cornerPadding == nil, chrome.border == nil,
              chrome.borderColor == nil, chrome.borderWidth == nil, chrome.separation == nil else { return false }
        return ChromeTunables.mainPaneCurved.override == nil && ChromeTunables.mainPaneGutter.override == nil
            && ChromeTunables.mainPaneCornerRadius.override == nil
    }

    /// The flush corner was picked in Debug Settings, not taken by default, and draws (compact keeps
    /// the pill): only then does it replace the sidebar's edge line, which `sidebar.border` sets otherwise.
    @MainActor public static var isChosen: Bool { tunable.override != nil && current.isOn }

    public var isOn: Bool { self != .off }

    /// The radius of the concave fillets where the selected tab meets the card (`flush-goo`); 0 for
    /// every other value.
    @MainActor public var feetRadius: CGFloat { self == .goo ? Metrics.scale(8) : 0 }

    /// The card's radius in a window with square corners (fullscreen, borderless): the titled window's
    /// radius less the frame's gap, as windowed (12 pt in macOS 26's 16 pt corner, 6 pt in macOS 15's 10 pt),
    /// so a fullscreen toggle reshapes no corner. A fixed 12 pt, scaled, read 12 against a windowed 6 on
    /// macOS 15 and 15 against 11 at a 1.25 interface scale.
    @MainActor public var cardRadius: CGFloat { max(0, Metrics.standardWindowCornerRadius - gap) }

    /// The frame's gap around the card (window edges, sidebar side under `flush`).
    @MainActor public var gap: CGFloat { Metrics.scale(LayoutGrid.base) }

    /// The gap on the sidebar's side of the card: none under `flush-tight`; nil when off (the main pane's gutter).
    @MainActor public var sidebarGap: CGFloat? { isOn ? (self == .tight ? 0 : gap) : nil }

    /// The frame's shade over the card's surface: the main pane's separate-surface shade, so the
    /// card reads on any theme.
    @MainActor public func shade(isDark: Bool) -> CGFloat {
        CGFloat((isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight).value)
    }
}

/// What a tab strip tells the window root about the flush corner: its frame in the window and
/// whether its selected tab is its first, flush on the strip's leading edge.
@MainActor
public protocol TabStripCorner: AnyObject {
    /// The strip's bounds in window coordinates.
    var cornerFrameInWindow: CGRect { get }
    /// The selected tab is the strip's first, unscrolled, so its leading side is the pane's edge.
    var selectsLeadingTab: Bool { get }
    /// The pane's content starts with a toolbar row right under the strip (a browser's omnibar): the tab row's
    /// divider leaves this pane out, so its tabs and its toolbar read as one surface (Lawrence, 2026-11-13: "get rid
    /// of border between tabs and omnibar, at all density levels").
    var meetsToolbar: Bool { get }
    /// Whether the strip is on the card's top row, where the frame's shade is behind it: only there does
    /// its selected tab run into the card. A strip inside the card (a lower split pane's) tones its own row
    /// instead (``setTonedInCard(_:)``): a tab in the card's own color would hide on an untoned row.
    func setRunsIntoCard(_ runs: Bool)
    /// Whether the strip is inside the card (a lower split pane's) while the top row's tabs are folders: it then
    /// tones its own row as the frame's shade tones the top row, so its selected tab is a folder too, in the
    /// content's surface and opening into it, never a pill in the card.
    func setTonedInCard(_ toned: Bool)
    /// The selected tab's folder (its body down to the card and its fillets) in `target`'s coordinates, while
    /// it runs into the card; nil otherwise. The chrome's shade leaves it out (``Palette/folderTabFill``).
    func selectedFolderPath(in target: CALayer) -> CGPath?
}

extension Metrics {
    /// What reshapes the main pane's chrome beside its numbers (`WindowRootView.observeMainPane`):
    /// floating panes, the flush corner and the card's radius in a titled window, which rounds from the
    /// tabs (``mainPaneRoundsFromTabs``), so a density change reshapes it too.
    public static var chromeShapeKey: CGFloat {
        let shape = CGFloat((floatingPanes ? 1 : 0) + 2 * (CornerFlush.allCases.firstIndex(of: CornerFlush.current) ?? 0))
        return shape + 16 * mainPaneCornerRadius(windowCornerRadius: standardWindowCornerRadius)
    }
}

/// The flush corner's part of the window root: the frame's wedges at the card's top corners, above the
/// content the card holds (a terminal or a page is opaque and would show a square corner over the
/// shade's curve), each a radius-sized square less the card's quarter circle in the shade's black; and
/// the strips that reported their first tab. The leading wedge goes while the shown strip at that
/// corner selects its first tab, so the card's edge rises straight into the tab. Takes no clicks.
public final class CornerFlushChrome: NSView {
    private let wedges = CAShapeLayer()
    /// Every tab strip of this window that reported (``stripDidChange(_:)``), weakly; a workspace's strips
    /// report while hidden too.
    private let strips = NSHashTable<AnyObject>.weakObjects()
    /// What the wedges were last drawn for (``apply``), so a strip's report redraws them alone.
    /// `card` is the content's whole frame; the card below the tab row is its top less a strip.
    private var drawn: (card: CGRect, radius: CGFloat, alpha: CGFloat)?
    /// The shade under the content, whose hole goes square with the leading wedge.
    private weak var shade: MainPaneChromeShadeView?
    /// The content the card holds, whose top corners round again while no strip shows.
    private weak var content: NSView?

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        layer?.addSublayer(wedges)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// A strip's selected tab became, or stopped being, its first: its window's wedges follow in this
    /// same pass, so the corner changes in the tab's frame (a direct call, no broadcast).
    /// `strip` finds its window's chrome among its ancestors' subviews (the window root holds it).
    /// Returns false when none holds it yet (a strip laid out before its workspace joins the window):
    /// the strip reports again on its next layout.
    @discardableResult
    public static func stripDidChange(_ strip: any TabStripCorner & NSView) -> Bool {
        var view = strip.superview
        while let ancestor = view {
            if let chrome = ancestor.subviews.lazy.compactMap({ $0 as? CornerFlushChrome }).first {
                chrome.strips.add(strip)
                if chrome.isHidden {
                    strip.setRunsIntoCard(false)
                    strip.setTonedInCard(false)
                } else {
                    chrome.redraw()
                }
                return true
            }
            view = ancestor.superview
        }
        return false
    }

    /// The card top inset in `root` that centers the top row's pills on the traffic lights' line, where
    /// the sidebar's `+` sits too; nil when the flush corner is off or the tabs are at the bottom. It
    /// may be negative: the strip's own top padding then sits above the window.
    static func topInset(of root: NSView) -> CGFloat? {
        guard CornerFlush.current.isOn, DesignSettings.shared.tabBarPosition != .bottom, let window = root.window,
              let lights = WindowTitlebar.trafficLightsFrame(in: window) else { return nil }
        let centerFromTop = root.bounds.maxY - root.convert(lights, from: nil).midY
        let scale = window.backingScaleFactor
        let chrome = PaneChromeMetrics.current
        let pillCenter = chrome.panePadding + chrome.pillTop(scale: scale) + Metrics.tabHeight / 2
        return ((centerFromTop - pillCenter) * scale).rounded() / scale
    }

    /// Shades the chrome around `content` (`shade`, in `root`'s unflipped coordinates): under the flush
    /// corner around its part below the top tab row, whose top corners the wedges drawn here round, with
    /// only the content's bottom corners clipped; else around the content's frame, with no wedges. Joins
    /// `root` above `content` either way, so the strips find it (``stripDidChange(_:)``).
    public func apply(content: NSView, radius: CGFloat, isDark: Bool, page: Bool,
                      shade: MainPaneChromeShadeView, in root: NSView) {
        let alpha = Metrics.mainPaneChromeShade(isDark: isDark)
        let card = content.frame
        let on = CornerFlush.current.isOn && !page && DesignSettings.shared.tabBarPosition != .bottom
        Self.roundBottomOnly(content, on)
        if content.superview === root, superview !== root || root.subviews.firstIndex(of: self) != (root.subviews.firstIndex(of: content) ?? 0) + 1 {
            root.addSubview(self, positioned: .above, relativeTo: content)
        }
        // A shade of 0 (`appearance.titleAreaContrast` 0, one colour) still draws here: the tab row keeps its
        // divider, and the selected tab its pill (``redraw()``).
        guard on, Metrics.mainPaneChromeShadeBase(isDark: isDark) > 0, radius > 0, superview === root else {
            isHidden = true
            markTopRow(card: nil, in: root)
            shade.update(card: card, radius: radius, alpha: alpha)
            return
        }
        frame = root.bounds
        isHidden = false
        drawn = (card, radius, alpha)
        self.shade = shade
        self.content = content
        redraw()
    }

    private func redraw() {
        guard let drawn, let root = superview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        wedges.frame = bounds
        var card = drawn.card
        let stripHeight = PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
        card.size.height = max(0, card.height - stripHeight) // the top is maxY
        // A top pane hid its strip or its strip left the top (vertical tabs, a hidden tab bar, a canvas
        // pan): no whole tab row, so the card is the whole content, rounded on every corner, with no
        // wedges and no shade band over that pane's content.
        guard hasTopStrip(card: card, in: root) else {
            wedges.path = nil
            markTopRow(card: nil, in: root)
            if let content { Self.roundBottomOnly(content, false) }
            shade?.update(card: drawn.card, radius: drawn.radius, alpha: drawn.alpha)
            return
        }
        // Under the least shade that sets the content apart (a title area contrast near 0: the tab row in the
        // content's own colour), a tab in the content's colour would vanish into the row: the selected tab keeps
        // its pill (`Palette.selectionFill`), the content its four round corners, and only the divider marks the
        // row's edge. Lawrence's single colour with a highlighted tab.
        guard drawn.alpha >= Metrics.folderTabMinimumShade else {
            wedges.path = nil
            markTopRow(card: nil, in: root)
            if let content { Self.roundBottomOnly(content, false) }
            let edge = tabRowEdge(card: card, in: root)
            shade?.update(card: drawn.card, radius: drawn.radius, alpha: drawn.alpha,
                          dividers: Self.dividerSegments(Self.dividerLine(card: edge, radius: 0, squareLeading: true),
                                                         leaving: toolbarPanes(card: edge, in: root)))
            return
        }
        if let content { Self.roundBottomOnly(content, true) }
        let square = leadingTabSelected(card: card, in: root)
        markTopRow(card: card, radius: drawn.radius, squareLeading: square, in: root)
        wedges.path = Self.wedgePath(card: card, radius: drawn.radius, squareLeading: square)
        wedges.fillColor = NSColor.black.withAlphaComponent(drawn.alpha).cgColor
        // Each wedge shades its corner once, including over transparent content.
        let edge = tabRowEdge(card: card, in: root)
        shade?.update(card: card, radius: drawn.radius, alpha: drawn.alpha, squareTopCorners: true,
                      folders: folderHoles(card: card, in: root),
                      dividers: Self.dividerSegments(Self.dividerLine(card: edge, radius: drawn.radius, squareLeading: square),
                                                     leaving: toolbarPanes(card: edge, in: root)))
    }

    /// The tab row's divider: the card's top edge (maxY is the top) between its rounded corners, as a rect of no
    /// height (`MainPaneChromeShadeView` gives it a hairline's thickness and leaves the selected folder tabs out,
    /// so the line runs under the unselected tabs and ends where a folder's fillet curves into the content).
    /// `radius` 0: the whole width (the pill look, whose card top is the tab row's top). Leo, 2026-11-12, on the
    /// two tones: "THERE IS THE DIVIDER THERE ARE WAYS TO MAKE THE 'BACKGROUND' LESS CONTRAST THAN IT DOES NOW".
    static func dividerLine(card: CGRect, radius: CGFloat, squareLeading: Bool) -> CGRect {
        let r = min(radius, card.width / 2, card.height / 2)
        let minX = card.minX + (squareLeading ? 0 : r), maxX = card.maxX - r
        return CGRect(x: minX, y: card.maxY, width: max(0, maxX - minX), height: 0)
    }

    /// The divider's segments: `line` less the horizontal spans in `gaps` (the panes whose toolbar meets their tabs,
    /// ``TabStripCorner/meetsToolbar``), left to right; empty segments are dropped. O(gaps log gaps).
    static func dividerSegments(_ line: CGRect, leaving gaps: [ClosedRange<CGFloat>]) -> [CGRect] {
        guard line.width > 0 else { return [] }
        var segments: [CGRect] = []
        var start = line.minX
        for gap in gaps.sorted(by: { $0.lowerBound < $1.lowerBound }) where gap.upperBound > start && gap.lowerBound < line.maxX {
            if gap.lowerBound > start { segments.append(CGRect(x: start, y: line.minY, width: gap.lowerBound - start, height: 0)) }
            start = max(start, gap.upperBound)
        }
        if start < line.maxX { segments.append(CGRect(x: start, y: line.minY, width: line.maxX - start, height: 0)) }
        return segments
    }

    /// The horizontal spans, in `root`, of the panes on the tab row (their strip's bottom on `card`'s top) whose toolbar
    /// meets their tabs: the whole pane, its trailing buttons included, so the divider stops at its split lines. O(strips).
    private func toolbarPanes(card: CGRect, in root: NSView) -> [ClosedRange<CGFloat>] {
        var spans: [ClosedRange<CGFloat>] = []
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects where strip.window === root.window && strip.meetsToolbar {
            guard let pane = strip.superview, !strip.isHiddenOrHasHiddenAncestor,
                  abs(root.convert(strip.cornerFrameInWindow, from: nil).minY - card.maxY) < 2 else { continue }
            let frame = root.convert(pane.bounds, from: pane)
            spans.append(frame.minX...frame.maxX)
        }
        return spans
    }

    /// `card` with its top on the top row's strips' bottom edge, where the tab row's divider sits. The card's top
    /// (the content less ``Metrics/tabStripHeight``) can sit a point inside the panes' content, under their opaque
    /// tops, so a divider drawn there was hidden at the default 1 pt (cmux#41640's one-colour captures). The strips
    /// report their frames (``TabStripCorner/cornerFrameInWindow``); with none on the row the card is unchanged.
    /// O(strips).
    private func tabRowEdge(card: CGRect, in root: NSView) -> CGRect {
        var bottom: CGFloat?
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects where strip.window === root.window {
            guard !strip.isHiddenOrHasHiddenAncestor else { continue }
            let minY = root.convert(strip.cornerFrameInWindow, from: nil).minY
            guard abs(minY - card.maxY) < 2 else { continue }
            bottom = max(bottom ?? minY, minY)
        }
        guard let bottom else { return card }
        var edge = card
        edge.size.height = max(0, bottom - card.minY)
        return edge
    }

    /// The selected folder tabs of the strips on the card's top row, in the shade's coordinates: the
    /// shade leaves them out, so a folder tab shows the same glass as the content (``Palette/folderTabFill``).
    /// The caller asks only while the shade reads (``Metrics/folderTabMinimumShade``); under it the folder
    /// keeps the selection fill over the shade. O(strips).
    private func folderHoles(card: CGRect, in root: NSView) -> [CGPath] {
        guard let target = shade?.layer else { return [] }
        var holes: [CGPath] = []
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects where strip.window === root.window {
            guard !strip.isHiddenOrHasHiddenAncestor, abs(root.convert(strip.cornerFrameInWindow, from: nil).minY - card.maxY) < 2,
                  let path = strip.selectedFolderPath(in: target) else { continue }
            holes.append(path)
        }
        return holes
    }

    /// Whether the window's tab row is whole: some shown pane's strip sits on the card's top, and every
    /// shown pane that reaches above it (a pane in the top row, a canvas pane panned up) shows its strip
    /// right there. A pane that hid its strip (vertical tabs, a hidden tab bar) or whose strip left the
    /// top (a canvas pan) has its own content at the card's top, where a wedge or the tab row's shade
    /// would cover it. The frames are fresh: a strip reports whenever its frame in the window changes
    /// (``TabStripView``'s layout and pane moves), after its pane took the frame. O(strips).
    private func hasTopStrip(card: CGRect, in root: NSView) -> Bool {
        var onTop = false
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects where strip.window === root.window {
            guard let pane = strip.superview, !pane.isHiddenOrHasHiddenAncestor else { continue }
            guard root.convert(pane.bounds, from: pane).maxY > card.maxY + 2 else { continue } // below the top row
            guard !strip.isHidden, abs(root.convert(strip.cornerFrameInWindow, from: nil).minY - card.maxY) < 2 else { return false }
            onTop = true
        }
        return onTop
    }

    /// Tells each strip of this window whether it is on the top row of `card` (nil: no tab row, so none
    /// is), so only those run their selected tab into the card; the rest, inside the card, tone their own row
    /// while the top row's tabs are folders. O(strips); a strip relays out only on a change.
    private func markTopRow(card: CGRect?, radius: CGFloat = 0, squareLeading: Bool = false, in root: NSView) {
        var clip = card
        if squareLeading {
            clip?.origin.x -= radius
            clip?.size.width += radius
        }
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects where strip.window === root.window {
            let onTop = card.map { !strip.isHidden && abs(root.convert(strip.cornerFrameInWindow, from: nil).minY - $0.maxY) < 2 } ?? false
            strip.setRunsIntoCard(onTop)
            strip.setTonedInCard(card != nil && !onTop && !strip.isHidden)
            for case let area as PaneContentAreaView in strip.superview?.subviews ?? [] {
                area.setChromeClip(card: onTop ? clip : nil, radius: radius, in: root)
            }
        }
    }

    /// Whether the shown strip at the card's top leading corner (minX) selects its first tab. Tabs run from minX
    /// whichever side the sidebar is on, so a sidebar on the right squares this corner too: the first tab's
    /// folder has no foot on its leading side, and over a rounded corner it ended in a 12 pt shaded notch.
    private func leadingTabSelected(card: CGRect, in root: NSView) -> Bool {
        for case let strip as (any TabStripCorner) in strips.allObjects {
            guard let view = strip as? NSView, view.window === root.window, !view.isHiddenOrHasHiddenAncestor else { continue }
            let frame = root.convert(strip.cornerFrameInWindow, from: nil)
            if abs(frame.minX - card.minX) < 1, abs(frame.minY - card.maxY) < 2 { return strip.selectsLeadingTab }
        }
        return false
    }

    /// Clips only the content's bottom corners (its top is under the tab row, rounded by the wedges), or all four.
    private static func roundBottomOnly(_ content: NSView, _ bottomOnly: Bool) {
        guard let layer = content.layer else { return }
        let bottom: CACornerMask = content.isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let corners: CACornerMask = bottomOnly ? bottom : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        guard layer.maskedCorners != corners else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.maskedCorners = corners
        CATransaction.commit()
    }

    /// The top corner squares (maxY is the top) less the card's rounded rect; without the
    /// leading one (minX, where the first tab sits) when `squareLeading`.
    public static func wedgePath(card: CGRect, radius: CGFloat, squareLeading: Bool) -> CGPath {
        let r = min(radius, card.width / 2, card.height / 2)
        let corners = CGMutablePath()
        for (x, leading) in [(card.minX, true), (card.maxX - r, false)] where !(leading && squareLeading) {
            corners.addRect(CGRect(x: x, y: card.maxY - r, width: r, height: r))
        }
        return corners.subtracting(CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil))
    }
}
