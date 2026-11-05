public import AppKit
import CmuxNextCompat
import CmuxNextDesignTokens

/// A tab strip the goo look reads and restyles (`TabStripView`).
@MainActor
public protocol GooStripSource: NSView {
    /// The selected tab's pill as it shows now, moves in flight included, in window coordinates.
    var selectedPillInWindow: CGRect? { get }
    var hasTabMovesInFlight: Bool { get }
    /// The goo look draws the selected tab as a droplet: the tab's own fill steps aside.
    var hidesSelectionFill: Bool { get set }
}

/// The sidebar the goo look reads (`SidebarContainerView`).
@MainActor
public protocol GooSidebarSource: NSView {
    /// Shown as a full sidebar (not hidden, not the rail).
    var gooShowsCard: Bool { get }
    var isWidthAnimating: Bool { get }
    /// The + as it shows, in window coordinates, and its reveal's alpha.
    var gooNewButtonInWindow: (frame: CGRect, alpha: CGFloat)? { get }
    /// Where the + sits under the look: the tabs' pill row in window coordinates (`GooMorphChrome.tabRow`).
    var gooNewButtonRow: (() -> (midY: CGFloat, height: CGFloat)?)? { get set }
}

/// The window the goo look draws in (its root view): what it reads of the window's state. A strip finds the
/// window's look through its root (`window.contentView`).
@MainActor
public protocol GooWindowHost: NSView {
    var goo: GooMorphChrome { get }
    var contentHost: MainPaneCardView { get }
    var mainPaneShade: MainPaneChromeShadeView { get }
    var content: NSView? { get }
    var presentsPage: Bool { get }
    var titlebarStyle: TitlebarStyle { get }
    var mainPaneCornerRadius: CGFloat { get }
    var gooSidebar: (any GooSidebarSource)? { get }
    var gooSidebarOnLeft: Bool { get }
    /// The look turned on or off: the window realigns the sidebar's header (its tokens).
    func applyTokens()
}

/// The goo look in one window (Thunderdome r2 C, Debug `chrome.gooMorph`): builds the scene from where the main
/// pane's card, its top-row strips and the sidebar show now, hands it to `GooMorphEngine`, and gives the shade
/// the traced surface. The top of the window is one band of chrome: the sidebar's header, the gutter and every
/// top-row tab strip share the chrome's shade, and the cards start under it, level. Each top-row strip's active
/// tab is a droplet of the card; in the pool looks the sidebar is a card too, with the + as its droplet on the
/// tabs' row.
@MainActor
public final class GooMorphChrome {
    public let engine = GooMorphEngine()
    private weak var host: (any GooWindowHost)?
    private var card: NSView? { host?.contentHost }
    private var strips: [ObjectIdentifier: WeakStrip] = [:]

    public init() {
        engine.scene = { [weak self] in self?.scene() }
        engine.draw = { [weak self] surface in
            guard let self else { return }
            host?.mainPaneShade.setGooSurface(surface, alpha: surface == nil ? 0 : shadeAlpha)
        }
    }

    /// Follows `host` and the Debug setting from now on.
    public func attach(_ host: some GooWindowHost) {
        self.host = host
        host.gooSidebar?.gooNewButtonRow = { [weak self] in self?.tabRow() }
        // Ends at the first change after the window's look is gone.
        Task { [weak self] in
            for await _ in ObservationStream({ GooMorphVariant.tunable.value }) {
                guard let self else { return }
                update()
            }
        }
    }

    /// The look this window's state allows: off over a page, with floating panes, an edge-to-edge pane or a full
    /// titlebar.
    private var variant: GooMorphVariant {
        guard let host, !host.presentsPage, Metrics.mainPaneCurved, !Metrics.floatingPanes, host.titlebarStyle == .minimal else { return .off }
        return GooMorphVariant.tunable.value
    }

    /// The chrome's shade under the look: the separate look's tint, so the band and the cards read apart even where
    /// the chrome otherwise shares the cards' surface.
    private var shadeAlpha: CGFloat {
        let isDark = host?.themeTokens.isDark ?? false
        let alpha = Metrics.mainPaneChromeShade(isDark: isDark)
        return alpha > 0 ? alpha : CGFloat((isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight).value)
    }

    public var isOn: Bool { engine.style != nil }

    /// The card moved, the theme or the window's state changed: restyle when the look changed, then redraw.
    public func update() {
        let style = variant.style
        guard style == engine.style else { return restyle(style) }
        if style != nil { engine.update() }
    }

    public func gooStripDidChange(_ strip: any GooStripSource) {
        guard isOn, strip.window === card?.window else { return }
        strips[ObjectIdentifier(strip)] = WeakStrip(strip)
        engine.update()
    }

    private func restyle(_ style: GooStyle?) {
        // Off, every strip it ever followed (a parked workspace's too) draws its own fill again.
        if style == nil { for strip in strips.values.compactMap(\.strip) + found { strip.hidesSelectionFill = false } }
        engine.host = card
        engine.style = style
        strips = [:]
        if style != nil { for strip in found { strips[ObjectIdentifier(strip)] = WeakStrip(strip) } }
        host?.applyTokens()
        engine.update()
    }

    /// Every strip in the card now, not looking inside a strip.
    private var found: [any GooStripSource] {
        guard let card else { return [] }
        var result: [any GooStripSource] = []
        var stack = [card]
        while let view = stack.popLast() {
            if let strip = view as? any GooStripSource { result.append(strip); continue }
            stack.append(contentsOf: view.subviews)
        }
        return result
    }

    /// The sidebar header's height under the look: down to the band's lower edge, so the list starts level with
    /// the cards; nil when off. `cardTop` is the card's distance from the window's top.
    public func headerHeight(cardTop: CGFloat) -> CGFloat? {
        variant == .off ? nil : cardTop + Metrics.tabStripHeight
    }

    /// The top-row tabs' pill row in window coordinates (its middle and height) for the sidebar's +; nil when off.
    public func tabRow() -> (midY: CGFloat, height: CGFloat)? {
        guard variant != .off, let card, let window = card.window else { return nil }
        let cardTop = card.convert(card.bounds, to: nil).maxY
        // A top-row strip's selected pill where it shows; else where a strip places it.
        for strip in strips.values.compactMap(\.strip) where strip.window === window && !strip.isHiddenOrHasHiddenAncestor {
            if let pill = strip.selectedPillInWindow, abs(strip.convert(strip.bounds, to: nil).maxY - cardTop) < 1.5 {
                return (pill.midY, pill.height)
            }
        }
        let metrics = PaneChromeMetrics.current
        let height = min(metrics.tabHeight, metrics.stripHeight)
        return (cardTop - metrics.pillTop(scale: window.backingScaleFactor) - height / 2, height)
    }

    private func scene() -> GooScene? {
        guard let style = engine.style, let host, let window = host.window, !host.contentHost.isHidden,
              let content = host.content, !content.isHidden else { return nil }
        let card = host.contentHost, shade = host.mainPaneShade, sidebar = host.gooSidebar
        let cardRect = shade.convert(card.bounds, from: card)
        let radius = host.presentsPage ? 0 : host.mainPaneCornerRadius
        // The shade is not flipped: a card's top is its maxY.
        var bandBottom: CGFloat?
        var droplets: [GooScene.Droplet] = []
        var live = sidebar?.isWidthAnimating ?? false
        for (key, weak) in strips {
            guard let strip = weak.strip else { strips[key] = nil; continue }
            guard strip.window === window, strip.isDescendant(of: content), !strip.isHiddenOrHasHiddenAncestor else { continue }
            let rect = shade.convert(strip.convert(strip.bounds, to: nil), from: nil)
            // Only a strip along the card's top edge is in the band; the others keep their own look.
            guard abs(rect.maxY - cardRect.maxY) < 1.5, rect.height > 1 else {
                strip.hidesSelectionFill = false
                continue
            }
            strip.hidesSelectionFill = true
            bandBottom = min(bandBottom ?? rect.minY, rect.minY)
            live = live || strip.hasTabMovesInFlight
            if let pill = strip.selectedPillInWindow {
                droplets.append(.init(key: key.hashValue, rect: shade.convert(pill, from: nil), group: 0, keepsMinY: true))
            }
        }
        guard let bandBottom, bandBottom > cardRect.minY + radius * 2 else { return nil }
        let bodyHeight = bandBottom - cardRect.minY
        var cards = [GooShape(rect: CGRect(x: cardRect.minX, y: cardRect.minY, width: cardRect.width, height: bodyHeight), radius: radius, group: 0)]
        var crossBlend: CGFloat = 0
        var crossWindow: CGRect?
        if style.sidebarCard, let sidebar, sidebar.gooShowsCard {
            let gutter = Metrics.mainPaneGutter, left = host.gooSidebarOnLeft
            let frame = shade.convert(sidebar.bounds, from: sidebar)
            // The window-edge side insets by the gutter; the card side's gutter is the main card's.
            let minX = left ? frame.minX + gutter : frame.minX, maxX = left ? frame.maxX : frame.maxX - gutter
            let width = maxX - minX
            if width > 0.5 {
                // Narrow (mid-slide), the sidebar's card melts out of the field and flows into the pane's card across
                // the gutter: it buds out of it as it opens and is drawn back in as it closes.
                let weight = Self.smoothstep(width, from: gutter, to: 64)
                crossBlend = 1 - Self.smoothstep(width, from: 40, to: 150)
                let side = GooShape(rect: CGRect(x: minX, y: cardRect.minY, width: width, height: bodyHeight), radius: radius, group: 1, weight: weight)
                cards.append(side)
                if crossBlend > 0 {
                    let gap = left ? CGRect(x: maxX, y: cardRect.minY, width: max(1, cardRect.minX - maxX), height: bodyHeight)
                        : CGRect(x: cardRect.maxX, y: cardRect.minY, width: max(1, minX - cardRect.maxX), height: bodyHeight)
                    crossWindow = side.rect.union(gap)
                }
                if let plus = sidebar.gooNewButtonInWindow, plus.alpha > 0.01 {
                    let rect = shade.convert(plus.frame, from: nil)
                    // Clipped by the sidebar's edge as it slides away, the droplet melts with it.
                    let inside = Self.smoothstep(min(rect.minX - minX, maxX - rect.maxX), from: -rect.width / 2, to: 4)
                    droplets.append(.init(key: ObjectIdentifier(sidebar).hashValue, rect: rect, group: 1, keepsMinY: true,
                                          weight: weight * inside * min(1, plus.alpha)))
                }
            }
        }
        return GooScene(cards: cards, droplets: droplets, crossBlend: crossBlend, crossWindow: crossWindow, live: live)
    }

    private static func smoothstep(_ x: CGFloat, from a: CGFloat, to b: CGFloat) -> CGFloat {
        guard b != a else { return x >= b ? 1 : 0 }
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// A strip the goo look follows, held weakly.
private struct WeakStrip {
    weak var strip: (any GooStripSource)?
    init(_ strip: any GooStripSource) { self.strip = strip }
}
