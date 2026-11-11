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
/// The default is `flush-goo` (Leo, 2026-11-10, design/selected-is-foreground.md): the selected tab
/// is the foreground, in the content's own surface, and joins the content like a folder tab, one
/// shape with concave corners where it meets the content's edge, in place of the gray pill: "We
/// can like morph it in as like, you know how folder tabs look, right? ... Make it look cohesive."
public nonisolated enum CornerFlush: String, Sendable, CaseIterable, TunableChoice {
    /// The old corner: the selected tab is a gray pill on the strip.
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
        case .off: "Off: the selected tab is a gray pill"
        case .flush: "Flush: the first tab rises from the card's edge"
        case .tight: "Flush, tight: the card meets the sidebar"
        case .goo: "Flush, goo: the selected tab flows into the card"
        }
    }

    public static let tunable = Tunable<CornerFlush>.choice(
        "chrome.cornerFlush", .sidebar, "Corner flush",
        help: "Thunderdome r2 A: the sidebar, the titlebar and the tab strips are one frame around a rounded content card; the selected tab is the card's color and runs into it, and each strip's first tab starts on its pane's edge, so the sidebar's edge rises straight into the first tab. Default flush-goo: the selected tab is the content's surface and joins it like a folder tab (design/selected-is-foreground.md). Off: the gray pill.",
        default: .goo, code: "CornerFlush.tunable")

    /// The value in effect, at every density. Compact density kept the old corner while this was a
    /// Debug opt-in; the folder tab is the selected state now (design/selected-is-foreground.md), and
    /// Compact is the default density, so it applies there too.
    ///
    /// The default joins the selected tab to the card (Leo, 2026-11-10: "We can go under that paradigm
    /// instead of the current stuff that we have"), and the card with it, in the default window:
    /// `appearance.chromeStyle` unset reads as `flat` (`ChromeStyleSetting.fallback`, never written to
    /// the file), so `flat` takes the folder tab. A style the user picked that has no card (bare, panes,
    /// flat-sidebar-line), a Debug override that turns the curved pane off, or a set
    /// `layout.panePadding` keeps the layout chosen and its gray selection, since the folder tab
    /// needs the card and puts each strip's first tab on the card's edge. A Debug Settings value for
    /// `chrome.cornerFlush` applies as set.
    @MainActor public static var current: CornerFlush {
        if let set = tunable.override { return set }
        let design = DesignSettings.shared
        guard ChromeTunables.mainPaneCurved.override != false, design.paneChrome.padding == nil else { return .off }
        let style = design.chromeStyle
        guard style == .default || style == .flat || style.curvedMainPane == true else { return .off }
        return tunable.defaultValue
    }

    public var isOn: Bool { self != .off }

    /// The radius of the concave fillets where the selected tab meets the card (`flush-goo`); 0 for
    /// every other value.
    @MainActor public var feetRadius: CGFloat { self == .goo ? Metrics.scale(8) : 0 }

    /// The card's radius: one grid step inside the 16 pt window corner (design/grid.md radii).
    @MainActor public var cardRadius: CGFloat { Metrics.scale(12) }

    /// The frame's gap around the card (window edges, sidebar side under `flush`).
    @MainActor public var gap: CGFloat { Metrics.scale(LayoutGrid.base) }

    /// The gap on the sidebar's side of the card: none under `flush-tight`; nil when off (the main pane's gutter).
    @MainActor public var sidebarGap: CGFloat? { isOn ? (self == .tight ? 0 : gap) : nil }

    /// The frame's shade over the card's surface: the main pane's separate-surface shade, so the
    /// card reads on any theme.
    /// A style with a shade of its own (two-tone, floating, blocks) keeps it: the folder tab changes
    /// the selection, not a style's look; a Debug override wins, as for the main pane's shade.
    @MainActor public func shade(isDark: Bool) -> CGFloat {
        let tunable = isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight
        return tunable.override.map { CGFloat($0) }
            ?? DesignSettings.shared.chromeStyle.separateShade(isDark: isDark)
            ?? CGFloat(tunable.defaultValue)
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
    /// The selected tab's folder shape and the layer it is drawn in, while it runs into the card; nil
    /// otherwise (design/selected-is-foreground.md).
    var selectedFolder: (path: CGPath, layer: CALayer)? { get }
    /// The selected folder along a move in flight (its tab's width or slot), in the folder layer's
    /// coordinates as ``selectedFolder`` gives them; nil at rest.
    var selectedFolderMotion: FolderMotion? { get }
    /// Something under the strip (its pane's own backdrop, its own fill) covers the window's shade: the
    /// strip draws its own band, on the top row too.
    var coversWindowShade: Bool { get }
    /// The window's chrome changed under the strip (its frame drawn or hidden, its band): the strip
    /// redraws its band and decides again whether its folder is seen. Reports nothing back.
    func chromeDidChange()
}

extension TabStripCorner {
    public var selectedFolderMotion: FolderMotion? { nil }
    public var coversWindowShade: Bool { false }
    public func chromeDidChange() {}
}

extension Metrics {
    /// What reshapes the main pane's chrome beside its numbers (`WindowRootView.observeMainPane`):
    /// floating panes and the flush corner.
    public static var chromeShapeKey: CGFloat {
        CGFloat((floatingPanes ? 1 : 0) + 2 * (CornerFlush.allCases.firstIndex(of: CornerFlush.current) ?? 0))
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
    private var drawn: (card: CGRect, radius: CGFloat, alpha: CGFloat, sidebarOnLeft: Bool)?
    /// The band every strip draws while the frame is hidden but the folder tab is on: Floating Panes
    /// (a main-pane radius of 0) floats each pane on the window's surface, with no frame shade under
    /// its strip, so the strip draws the chrome's shade itself (0 otherwise).
    private var hiddenBand: CGFloat = 0
    /// The shade under the content, whose hole goes square with the leading wedge.
    private weak var shade: MainPaneChromeShadeView?
    /// A shown tab strip runs along the card's top (the top row), as of the last ``apply``. Without one
    /// (vertical tabs, a hidden tab bar, an app workspace, Home Chief) the card keeps its whole frame,
    /// its four rounded corners and no wedges, and the top inset is the gutter's, so no shade or pill
    /// line is left where no strip is. True until a strip has reported (nothing known yet).
    private(set) var topRowHasStrip = true
    /// The content the last ``apply`` framed, so a strip's report can tell whether the top row changed.
    private weak var framedContent: NSView?
    /// Inside ``redraw``, which reports every strip: the top row is checked once, after them.
    private var redrawing = false

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
                if !chrome.isHidden { chrome.redraw() }
                chrome.checkTopRow()
                return true
            }
            view = ancestor.superview
        }
        return false
    }

    /// The window's chrome that `strip` reports to: the one among its ancestors' subviews.
    public static func chrome(of strip: NSView) -> CornerFlushChrome? {
        var view = strip.superview
        while let ancestor = view {
            if let chrome = ancestor.subviews.lazy.compactMap({ $0 as? CornerFlushChrome }).first { return chrome }
            view = ancestor.superview
        }
        return nil
    }

    /// A strip's selected folder tab appeared, moved or went (`animated`: a selection change, faded
    /// with the tabs): the frame's shade cuts it away when the strip is on the frame (the top row),
    /// so the tab shows what the content shows over a see-through window. `gone`: the strip left
    /// this window or its sight; its hole closes. Returns the band the strip draws itself
    /// (``bandShade(for:)``), 0 for none.
    @discardableResult
    public func folderDidChange(_ strip: any TabStripCorner & NSView, animated: Bool, gone: Bool = false) -> CGFloat {
        strips.add(strip)
        checkTopRow()
        let band = gone ? 0 : bandShade(for: strip)
        guard let shade, let shadeLayer = shade.layer else { return band }
        let key = ObjectIdentifier(strip)
        if !gone, cutsHole(for: strip, band: band), let folder = strip.selectedFolder {
            let motion = animated ? nil : strip.selectedFolderMotion?.map { shadeLayer.converted($0, from: folder.layer) }
            shade.setFolder(key, path: shadeLayer.converted(folder.path, from: folder.layer), animated: animated, motion: motion)
        } else {
            shade.setFolder(key, path: nil, animated: animated && !gone)
        }
        return band
    }

    /// Whether the frame's shade is cut away under `strip`'s folder: the frame is drawn and the strip, shown,
    /// sits on it with no band of its own (`band`: ``bandShade(for:)``).
    public func cutsHole(for strip: any TabStripCorner & NSView, band: CGFloat) -> Bool {
        !isHidden && drawn != nil && shade != nil && band == 0 && !strip.isHiddenOrHasHiddenAncestor
    }

    /// The chrome band `strip` draws under its tabs (design/selected-is-foreground.md): every tab strip
    /// is chrome, so its selected tab, in the content's surface, reads as the foreground. A strip on
    /// the frame (its bottom on the card's top edge) sits on the frame's shade already and draws none;
    /// a strip inside the card (a lower pane's, or any pane's when panes float) draws the frame's
    /// shade itself. 0 while the flush corner is off or the strip is in another window.
    public func bandShade(for strip: any TabStripCorner & NSView) -> CGFloat {
        guard let root = superview, strip.window === root.window else { return 0 }
        if isHidden { return hiddenBand }
        guard let drawn else { return 0 }
        let frame = root.convert(strip.cornerFrameInWindow, from: nil)
        // A pane painting its own backdrop covers the frame's shade under its strip (Codex at b01bf4ed, F1).
        let onFrame = abs(frame.minY - drawn.card.maxY) < 2 && !Metrics.floatingPanes && !strip.coversWindowShade
        return onFrame ? 0 : drawn.alpha
    }

    /// The card top inset in `root` that centers the top row's pills on the traffic lights' line, where
    /// the sidebar's `+` sits too; nil when the flush corner is off or the tabs are at the bottom. It
    /// may be negative: the strip's own top padding then sits above the window.
    static func topInset(of root: NSView) -> CGFloat? {
        // No strip in the top row: no pills to put on the lights' line.
        if let chrome = root.subviews.lazy.compactMap({ $0 as? CornerFlushChrome }).first, !chrome.topRowHasStrip { return nil }
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
    public func apply(content: NSView, radius: CGFloat, isDark: Bool, page: Bool, sidebarOnLeft: Bool,
                      shade: MainPaneChromeShadeView, in root: NSView) {
        let alpha = Metrics.mainPaneChromeShade(isDark: isDark)
        var card = content.frame
        let flush = CornerFlush.current.isOn && !page && DesignSettings.shared.tabBarPosition != .bottom
        framedContent = content
        // Only under the folder tab: off, nothing is trimmed and no strip lookup runs.
        let topRow = !flush || !stripsKnown(content: content, in: root) || topRowStrip(content: content, in: root)
        if topRow != topRowHasStrip {
            topRowHasStrip = topRow
            root.needsLayout = true // the top inset follows (`WindowRootView.layout`, `topInset(of:)`)
        }
        // The frame (trimmed card, wedges, the top row's folder holes) needs a strip along the card's top.
        let on = flush && topRow
        Self.roundBottomOnly(content, on)
        if content.superview === root, superview !== root || root.subviews.firstIndex(of: self) != (root.subviews.firstIndex(of: content) ?? 0) + 1 {
            root.addSubview(self, positioned: .above, relativeTo: content)
        }
        // Floating Panes, or a card with no top-row strip: every strip draws its own band.
        hiddenBand = flush && (Metrics.floatingPanes || !topRow) ? alpha : 0
        guard Self.drawsFrame(on: on, alpha: alpha, radius: radius, floating: Metrics.floatingPanes), superview === root else {
            isHidden = true
            shade.update(card: card, radius: radius, alpha: alpha)
            for case let strip as (any TabStripCorner & NSView) in strips.allObjects {
                shade.setFolder(ObjectIdentifier(strip), path: nil, animated: false)
                strip.chromeDidChange()
            }
            return
        }
        card.size.height = max(0, card.height - Metrics.tabStripHeight) // the top is maxY
        frame = root.bounds
        isHidden = false
        drawn = (card, radius, alpha, sidebarOnLeft)
        self.shade = shade
        redraw()
    }

    /// Whether the top row can be told: a strip of `root`'s window is known, or `content` is in a window.
    /// Before a strip has reported, the strips under `content` are looked up and kept (a strip hidden from
    /// launch, Hide Tab Bar or vertical tabs, may never lay out into a report), so the top row is known
    /// from the first frame; the walk runs only while no strip of the window is known.
    private func stripsKnown(content: NSView, in root: NSView) -> Bool {
        if strips.allObjects.contains(where: { ($0 as? NSView)?.window === root.window }) { return true }
        var stack: [NSView] = [content]
        var found = false
        while let view = stack.popLast() {
            if let strip = view as? (any TabStripCorner & NSView) {
                strips.add(strip)
                found = true
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        // In a window with no strip under its content at all, the top row has none.
        return found || content.window != nil
    }

    /// Whether shown strips run along `content`'s whole top edge (root's unflipped coordinates): every
    /// top-row pane has its strip. A top row where one pane hides its strip (Hide Tab Bar beside a
    /// strip, Home Chief beside a pane) keeps the whole card too, since a trim there would shade that
    /// pane's top and put a wedge over its content; its strips then draw their own band. O(strips).
    private func topRowStrip(content: NSView, in root: NSView) -> Bool {
        let top = content.frame.maxY
        var spans: [(CGFloat, CGFloat)] = []
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects {
            guard strip.window === root.window, !strip.isHiddenOrHasHiddenAncestor, strip.bounds.height > 0.5 else { continue }
            let frame = root.convert(strip.cornerFrameInWindow, from: nil)
            guard abs(frame.maxY - top) < 2, frame.width > 0.5 else { continue }
            // The pane's whole header: the strip shares its row with the pane's trailing toolbar and chat
            // controls, which the strip's own width leaves out (Codex at eceb7833, F1).
            let pane = strip.superview.map { root.convert($0.bounds, from: $0) } ?? frame
            spans.append((min(frame.minX, pane.minX), max(frame.maxX, pane.maxX)))
        }
        guard !spans.isEmpty else { return false }
        // Panes part by a divider or a gap of a few points at most.
        let slack = Metrics.scale(LayoutGrid.base) * 2
        var reach = content.frame.minX
        for (minX, maxX) in spans.sorted(by: { $0.0 < $1.0 }) {
            guard minX <= reach + slack else { return false }
            reach = max(reach, maxX)
        }
        return reach >= content.frame.maxX - slack
    }

    /// A strip reported on its own (not in a ``redraw``): when the top row gained or lost its strip, the
    /// root lays out again and the frame follows (``apply``). O(strips), once per report.
    private func checkTopRow() {
        guard !redrawing, let root = superview, let content = framedContent else { return }
        guard CornerFlush.current.isOn else { return }
        let topRow = !stripsKnown(content: content, in: root) || topRowStrip(content: content, in: root)
        if topRow != topRowHasStrip { root.needsLayout = true }
    }

    /// Whether the frame draws its shade and folder holes: the flush corner on, with a shade. Any card
    /// radius does, 0 included (`layout.paneCornerRadius` 0): the card is square and the folder tab
    /// joins its straight top edge (a square join, no wedges), so the selected tab keeps its surface
    /// against the shaded chrome (Codex at 2b1e6839, F1). Floating Panes and Blocks keep out: their main
    /// pane is radius 0 because each pane rounds its own card, the shade already leaves those cards out
    /// (`MainPaneChromeShadeView.paneCards`), and trimming the top strip off the card would leave shade
    /// behind the top strips, twice over a translucent window (Codex at 0f2ac599, F2). Their strips draw
    /// their own band (`hiddenBand`).
    static func drawsFrame(on: Bool, alpha: CGFloat, radius: CGFloat, floating: Bool) -> Bool {
        on && alpha > 0 && (radius > 0 || !floating)
    }

    private func redraw() {
        guard let drawn, let root = superview else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        wedges.frame = bounds
        let square = leadingTabSelected(card: drawn.card, in: root)
        wedges.path = Self.wedgePath(card: drawn.card, radius: drawn.radius, squareLeading: square)
        wedges.fillColor = NSColor.black.withAlphaComponent(drawn.alpha).cgColor
        // The shade under a translucent terminal would show the rounded corner the wedge no longer draws.
        shade?.update(card: drawn.card, radius: drawn.radius, alpha: drawn.alpha, squareTopLeading: square)
        // Every strip's hole follows the card at once (a resize, a workspace switch); the strips' own
        // bands follow on their next layout.
        redrawing = true
        for case let strip as (any TabStripCorner & NSView) in strips.allObjects {
            folderDidChange(strip, animated: false, gone: strip.window !== root.window)
            strip.chromeDidChange()
        }
        redrawing = false
    }

    /// Whether the shown strip at the card's top minX corner selects its first tab, whichever side the
    /// sidebar is on (the first tab's leading fillet goes for any strip's first tab, `reportCornerLead`).
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

    /// The top corner squares (maxY is the top) less the card's rounded rect; without the minX one when
    /// `squareLeading`: a strip's first tab sits on its leading (minX) edge whichever side the sidebar
    /// is on, so that is the corner its straight side rises from (as the shade's `squareTopLeading`).
    public static func wedgePath(card: CGRect, radius: CGFloat, squareLeading: Bool) -> CGPath {
        let r = min(radius, card.width / 2, card.height / 2)
        // A square card (`layout.paneCornerRadius` 0) has no rounded corner to fill: no wedge.
        guard r > 0 else { return CGMutablePath() }
        let corners = CGMutablePath()
        for (x, leading) in [(card.minX, true), (card.maxX - r, false)] where !(leading && squareLeading) {
            corners.addRect(CGRect(x: x, y: card.maxY - r, width: r, height: r))
        }
        return corners.subtracting(CGPath(roundedRect: card, cornerWidth: r, cornerHeight: r, transform: nil))
    }
}
