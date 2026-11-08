public import AppKit
public import CmuxNextDesignTokens

/// Layout constants shared by chrome components.
///
/// Compact is the default density: dense like a pro tool, but every value
/// sits on a 2 pt grid with consistent optical rhythm so it still reads as
/// designed. `Density.comfortable` exists for users who opt in; modules read
/// metrics through `Metrics` so a density switch changes every surface.
public enum Density: String, Sendable, CaseIterable, Codable {
    case compact
    case comfortable
}

public struct Metrics {
    public init() {}
    /// Applies the one live chrome multiplier (when `interfaceScaleEnabled`) to every metric token.
    public static func scale(_ value: CGFloat) -> CGFloat {
        value * (DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1)
    }
    /// Active density, read from `DesignSettings.shared`. Reading any metric
    /// inside an Observation-tracked scope (view layout, `withObservationTracking`)
    /// registers a dependency, so a density or override change re-lays out live.
    public static var density: Density { tokens.family }
    /// The active density's token set (`DensityTokens.active`): a scoped one while a preview
    /// draws, else the app's.
    public static var tokens: DensityTokens { DensityTokens.active }

    /// The user's `appearance.metrics.*` override, else the density's value for this metric
    /// (`DensityTokens.resolve`). Debug Settings overrides apply on top (`MetricTunable`).
    /// A `glyph` metric lands on the icon scale (`DensityTokens.resolveGlyph`).
    static func pick(_ compact: CGFloat, _ comfortable: CGFloat, _ key: MetricKey? = nil, token: String? = nil,
                     glyph: Bool = false) -> CGFloat {
        if let key, let value = DesignSettings.shared.overrides[key] { return value }
        if glyph { return tokens.resolveGlyph(compact: compact, comfortable: comfortable, token: token) }
        return tokens.resolve(compact: compact, comfortable: comfortable, token: token)
    }

    // MARK: Window chrome

    /// Default sidebar width when visible.
    public static var sidebarWidth: CGFloat { MetricTunables.sidebarWidth.value }
    public static var sidebarMinWidth: CGFloat { scale(ChromeTunables.sidebarMinWidth.value) }
    public static var sidebarMaxWidth: CGFloat { scale(ChromeTunables.sidebarMaxWidth.value) }

    /// Height of the unified titlebar area. The tab strip sits beside the
    /// traffic lights inside it.
    public static var titlebarHeight: CGFloat { MetricTunables.titlebarHeight.value }

    /// Height of a pane's tab strip: the density token, or, when `layout.cornerPadding` is set, the
    /// tab height with that gap above and below the pills (`PaneChromeMetrics`: the pill top is
    /// `(strip - tab - stripTopOutset) / 2`, so the padding is the gap the corners nest across).
    public static var tabStripHeight: CGFloat {
        guard let padding = DesignSettings.shared.paneChrome.cornerPadding else { return MetricTunables.tabStripHeight.value }
        return tabHeight + 2 * scale(padding) + stripTopOutset
    }

    /// Space reserved at the leading edge of the titlebar for traffic lights.
    public static var trafficLightInset: CGFloat { scale(ChromeTunables.trafficLightInset.value) }

    // MARK: Rows and tabs

    /// Sidebar workspace row with one line of text.
    public static var sidebarRowHeight: CGFloat { MetricTunables.sidebarRowHeight.value }
    /// Sidebar workspace row with a subtitle line (cwd, branch, agent status).
    public static var sidebarRowHeightWithSubtitle: CGFloat { MetricTunables.sidebarRowHeightWithSubtitle.value }
    /// Sidebar group / machine section header.
    public static var sidebarHeaderHeight: CGFloat { MetricTunables.sidebarHeaderHeight.value }

    /// A tab pill's height: the density's, or under `appearance.metrics.tabStripHeight` the bar's
    /// height less the density's room around the pill, so a taller bar has taller tabs.
    public static var tabHeight: CGFloat {
        let tab = MetricTunables.tabHeight.value
        guard DesignSettings.shared.overrides[.tabStripHeight] != nil else { return tab }
        let strip = MetricTunables.tabStripHeight
        let densityStrip = scale(strip.tunable.resolve(tokens.resolve(compact: strip.compactValue, comfortable: strip.comfortable, token: strip.name)))
        return max(tab + tabStripHeight - densityStrip, 0)
    }
    public static var controlHeight: CGFloat { MetricTunables.controlHeight.value }
    public static var tabMaxWidth: CGFloat { MetricTunables.tabMaxWidth.value }
    /// Chrome's crowding minimums and pinned width (`appearance.metrics.tabMinActiveWidth`,
    /// `tabMinInactiveWidth`, `tabPinnedWidth`; defaults from design-tokens.json `motion.tabStrip`).
    public static var tabMinActiveWidth: CGFloat { MetricTunables.tabMinActiveWidth.value }
    public static var tabMinInactiveWidth: CGFloat { MetricTunables.tabMinInactiveWidth.value }
    public static var tabPinnedWidth: CGFloat { MetricTunables.tabPinnedWidth.value }
    /// Icon-only width (pinned tabs and fully shrunk tabs).
    public static var tabMinWidth: CGFloat { MetricTunables.tabMinWidth.value }

    public static var paletteRowHeight: CGFloat { MetricTunables.paletteRowHeight.value }
    public static var paletteSearchHeight: CGFloat { MetricTunables.paletteSearchHeight.value }
    public static var paletteWidth: CGFloat { MetricTunables.paletteWidth.value }

    // MARK: Spacing (2 pt grid)

    public static var space1: CGFloat { scale(tokens.space(ChromeTunables.space1.value)) }
    public static var space2: CGFloat { scale(tokens.space(ChromeTunables.space2.value)) }
    public static var space3: CGFloat { scale(tokens.space(ChromeTunables.space3.value)) }
    public static var space4: CGFloat { scale(tokens.space(ChromeTunables.space4.value)) }
    public static var space5: CGFloat { scale(tokens.space(ChromeTunables.space5.value)) }
    public static var space6: CGFloat { scale(tokens.space(ChromeTunables.space6.value)) }

    /// Inset between the window edge and floating glass panels.
    public static var panelInset: CGFloat { MetricTunables.panelInset.value }
    /// Gap between strip columns.
    public static var columnGap: CGFloat { MetricTunables.columnGap.value }
    /// The column gap the column strip uses: `columnGap` for bordered and
    /// carded panes or when the user set it (`appearance.metrics.columnGap`
    /// or Debug Settings); 0 for the default edge-to-edge separations, whose
    /// columns meet at one line as split panes do.
    public static var stripColumnGap: CGFloat {
        let set = DesignSettings.shared.overrides[.columnGap] != nil || MetricTunables.columnGap.tunable.override != nil
        // Floating panes: the padding alone makes the one even gap.
        return set || !floatingPanes && (paneSeparation == .borders || paneSeparation == .cards) ? columnGap : 0
    }
    /// Divider thickness between split panes (hit area is wider).
    /// A room dot at the bottom of the sidebar (drawn size; its hit target
    /// is `roomDotSlot` wide and the bar's full height).
    public static var roomDotDiameter: CGFloat { MetricTunables.roomDotDiameter.value }
    public static var roomDotSlot: CGFloat { MetricTunables.roomDotSlot.value }

    /// Height of the fade at a scrolling list's top or bottom edge while
    /// content is hidden beyond it (`ScrollEdgeFade`).
    public static var scrollEdgeFade: CGFloat { MetricTunables.scrollEdgeFade.value }

    public static var dividerThickness: CGFloat { MetricTunables.dividerThickness.value }
    /// Width of the sidebar's resting edge line (`sidebar.border`,
    /// `sidebar.borderWidth`); 0 when off or under `appearance.borders` none.
    public static var sidebarBorderWidth: CGFloat {
        let border = DesignSettings.shared.sidebarBorder
        return border.shows ? lineWidth(border.width.map(scale) ?? dividerThickness) : 0
    }
    public static var dividerHitWidth: CGFloat { MetricTunables.dividerHitWidth.value }

    /// Inset around every pane's tab strip and content (`layout.panePadding`;
    /// 0 is edge to edge).
    public static var panePadding: CGFloat { scale(ChromeTunables.panePadding.resolve(codePanePadding)) }
    /// The part of the pane padding that counts toward the gap above a pane's
    /// tab pills (`PaneChromeMetrics`): the whole padding, since nothing is
    /// drawn above the strip and the cell's top is the edge the eye reads;
    /// 0 under Floating Panes, where each pane is one card whose own top edge
    /// sits the padding inside the cell (Lawrence 2026-10-19: the space above
    /// and below the tabs must be identical).
    public static var stripTopOutset: CGFloat { floatingPanes ? 0 : panePadding }
    /// `layout.panePadding`, else the density default (no Debug Settings override).
    static var codePanePadding: CGFloat {
        let chrome = DesignSettings.shared.paneChrome
        return chrome.padding ?? paneSeparation.impliedPadding ?? densityPanePadding
    }
    /// The density's pane padding in points (unscaled), used for padded
    /// panes when `layout.panePadding` is unset.
    public static var densityPanePadding: CGFloat { tokens.resolve(compact: 2, comfortable: 4, token: "panePadding") }

    // MARK: Pane alignment

    // A pane's tab pills and toolbar button shapes start on its content
    // border's left edge (the chrome line), and the terminal's first cell
    // sits `PaneChromeMetrics.terminalTextInset` inside it (dogfood
    // 2026-10-01, replacing nxdog12's separate content line).

    /// Half the gap between neighboring tab pills. Each pill leaves the
    /// whole gap at its trailing side, so the first pill starts on the
    /// chrome line.
    public static var tabBackgroundInset: CGFloat { scale(ChromeTunables.tabBackgroundInset.value) }
    /// Inset of a tab's icon from its pill's leading edge.
    public static var tabContentLeadingInset: CGFloat {
        scale((compactTabs ? ChromeTunables.compactTabContentLeadingInset : ChromeTunables.tabContentLeadingInset).value)
    }
    /// The opt-in tight tab strip (`ChromeTunables.compactTabs`), at compact density only.
    public static var compactTabs: Bool { density == .compact && ChromeTunables.compactTabs.value }
    /// The chrome line: tab pills and toolbar button shapes, from the
    /// strip's leading edge (`PaneChromeMetrics.pillLeading`: the pills' top
    /// inset, 0 for outlined panes). On the 2x pixel grid, where every
    /// density's default is whole points.
    public static var paneChromeInset: CGFloat { PaneChromeMetrics.current.pillLeading(scale: 2) }

    // MARK: Shape

    /// The one outer corner radius (`layout.paneCornerRadius`, else the density's
    /// ``densityPaneCornerRadius``): every rounded pane card, the curved main
    /// pane and, less ``cornerPadding``, every tab pill (Lawrence 2026-11-04: "radius
    /// of tabbar tabs ... + radius of panes, both need to be same setting").
    public static var cornerRadius: CGFloat {
        DesignSettings.shared.paneChrome.cornerRadius.map(scale) ?? densityPaneCornerRadius
    }
    /// The gap between a pane's rounded edge and the tab pills nested in it, which
    /// nested corners subtract from ``cornerRadius``: the first pill's inset from the
    /// card's top and leading edges (``tabStripCardInset``), set by `layout.cornerPadding`.
    public static var cornerPadding: CGFloat { tabStripCardInset }
    /// The concentric corner rule of the pane chrome: ``cornerRadius`` outside,
    /// ``cornerPadding`` between each nested level. Every pane and tab bar radius is
    /// read from it (``ConcentricCorners``).
    public static var corners: ConcentricCorners { ConcentricCorners(outer: cornerRadius, padding: cornerPadding) }
    /// Corner radius of a pane's rounded rect: ``cornerRadius``, or 0 (square)
    /// when panes are edge to edge (no padding and no border), where neighbors
    /// meet with no gap for a curve to show in.
    public static var paneCornerRadius: CGFloat {
        if panePadding == 0 && paneBorder == .none { return 0 }
        return cornerRadius
    }
    /// The radius of a shape `inset` points inside a pane, `size` big: concentric with the
    /// pane's corner (``paneCornerRadius``, or the one ``cornerRadius`` where panes are square
    /// inside the rounded main pane), at most half the shape's shorter side.
    public static func paneNestedCornerRadius(inset: CGFloat, size: CGSize) -> CGFloat {
        let corners = corners
        let pane = paneCornerRadius > 0 ? paneCornerRadius : corners.outer
        return corners.radius(fitting: size, radius: corners.nested(in: pane, inset: inset))
    }
    /// The density's outer corner radius, used when `layout.paneCornerRadius` is unset:
    /// the omnibar's 8 pt in every density (Lawrence 2026-11-05: "default roundness is too
    /// round now", "default roundness should be omnibar roundness"). The tab pills and the
    /// sidebar's rows nest the corner padding inside it; the main pane is less round than
    /// the 16 pt window across its 6 pt gutter, never rounder.
    public static var densityPaneCornerRadius: CGFloat { MetricTunables.densityPaneCornerRadius.value }
    /// How panes are told apart (`layout.paneSeparation`, else the legacy
    /// `layout.paneBorder` and padding).
    public static var paneSeparation: PaneSeparation {
        PaneSeparation.resolve(DesignSettings.shared.paneChrome, unset: defaultPaneSeparation)
    }
    /// The separation when cmux.json sets none: the `appearance.chromeStyle`
    /// one, else inside the curved main pane, whose gutter is the window's
    /// one inset, panes are flush and divided by one line (no padded,
    /// outlined box per pane); without it, borders.
    public static var defaultPaneSeparation: PaneSeparation {
        DesignSettings.shared.chromeStyle.paneSeparation ?? (mainPaneCurved ? .dividers : .borders)
    }
    /// Pane border: subtle only for the `borders` separation, and none
    /// under `appearance.borders` none. The line is one device pixel wide.
    public static var paneBorder: PaneBorderStyle {
        Borders.drawsLines && paneSeparation.drawsPaneBorder ? .subtle : .none
    }

    /// A border, hairline or stroke of `width` points: 0 under
    /// `appearance.borders` none (`Borders`).
    public static func lineWidth(_ width: CGFloat) -> CGFloat { Borders.width(width) }
    /// Pane border width in points (`layout.paneBorderWidth`); nil is one
    /// device pixel.
    public static var paneBorderWidth: CGFloat? { DesignSettings.shared.paneChrome.borderWidth.map(scale) }

    // MARK: Corner levels (one radius, concentric everywhere)

    /// The radius of every top-level rounded surface: panes, floating glass panels (sidebar,
    /// palette), popovers, menus, hover cards, cards, toasts, dialogs and sheets. It is the one
    /// outer radius (``corners``, `layout.paneCornerRadius`); a surface is a pane-like shape, so
    /// it shares the pane's corner (Lawrence 2026-11-04, "all nested radius everywhere ... must be
    /// concentric"). An explicit `appearance.metrics.panelCornerRadius` still wins for floating panels.
    public static var surfaceCornerRadius: CGFloat { corners.outer }
    /// A shape one level inside a surface (``ConcentricCorners/inner``): a tab pill, a row or
    /// selection fill in a list that pads it from the surface's edge, a menu highlight.
    public static var insetCornerRadius: CGFloat { corners.inner }
    /// A shape two levels inside a surface (`radius(depth: 2)`): a button, field, badge or
    /// thumbnail inside a row or pill.
    public static var controlCornerRadius: CGFloat { corners.radius(depth: 2) }
    /// The concentric radius of a shape `inset` points inside a shape of radius `outer`
    /// (`outer - inset`, at least 0), at most half the shorter side of `size` when given.
    public static func cornerRadius(nestedIn outer: CGFloat, inset: CGFloat, size: CGSize? = nil) -> CGFloat {
        let radius = corners.nested(in: outer, inset: inset)
        return size.map { corners.radius(fitting: $0, radius: radius) } ?? radius
    }
    /// The concentric radius of a shape `inset` points inside a top-level surface
    /// (``surfaceCornerRadius``), at most half the shorter side of `size` when given.
    public static func cornerRadius(insetFromSurface inset: CGFloat, size: CGSize? = nil) -> CGFloat {
        cornerRadius(nestedIn: surfaceCornerRadius, inset: inset, size: size)
    }
    /// The radius that makes a rect of `size` a capsule (half its shorter side): a shape choice
    /// (a slider track, a pill-shaped tag), not a radius level.
    public static func capsuleRadius(_ size: CGSize) -> CGFloat { corners.radius(fitting: size, radius: .greatestFiniteMagnitude) }

    /// Corner radius for floating glass panels (sidebar, palette): ``surfaceCornerRadius``, or an
    /// explicit `appearance.metrics.panelCornerRadius`.
    public static var panelCornerRadius: CGFloat {
        legacyRadius(.panelCornerRadius, token: "panelCornerRadius") ?? surfaceCornerRadius
    }
    /// Corner radius for tabs' controls, rows' buttons and other items: ``controlCornerRadius``, or
    /// an explicit `itemCornerRadius` token of a custom density.
    public static var itemCornerRadius: CGFloat { legacyRadius(nil, token: "itemCornerRadius") ?? controlCornerRadius }
    /// A radius the user set by its old name (an `appearance.metrics` override or a custom
    /// density's token), scaled; nil when unset, so the corner follows ``corners``.
    private static func legacyRadius(_ key: MetricKey?, token: String) -> CGFloat? {
        if let key, let value = DesignSettings.shared.overrides[key] { return scale(value) }
        return tokens.tokens[token].map { scale(CGFloat($0)) }
    }
    /// Corner radius for a small labeled surface (a note, toast or count
    /// badge) of `height`: the item radius, never a capsule.
    public static func chipCornerRadius(height: CGFloat) -> CGFloat {
        min(itemCornerRadius, (height / 4).rounded(.down))
    }

    // MARK: Icons

    public static var iconSize: CGFloat { MetricTunables.iconSize.value }
    public static var smallIconSize: CGFloat { MetricTunables.smallIconSize.value }
    /// The height of a row's status glyph and of the count badge beside it
    /// (Leo 2026-10-13: the badge stood taller than the glyph). Both the
    /// glyph's owner and the badge size from this one token.
    public static var statusMarkSize: CGFloat { smallIconSize - space1 }
}

/// Type scale, from the active density (`DensityTokens.textSize`). Compact uses 12 pt body in chrome (terminal fonts come from
/// the Ghostty config and are not affected).
public struct Typography {
    public init() {}
    /// User override for chrome body size; other styles scale from it.
    private static var scale: CGFloat {
        let interfaceScale = DesignSettings.shared.interfaceScaleEnabled ? DesignSettings.shared.interfaceScale : 1
        let configuredScale: CGFloat
        if let body = DesignSettings.shared.overrides[.chromeFontSize] {
            configuredScale = body / Metrics.tokens.bodySize
        } else {
            configuredScale = 1
        }
        return configuredScale * interfaceScale
    }
    /// The user's text size relative to the density's body size (1 when
    /// Interface Size is not overridden). Surfaces with their own type scale
    /// (the Home transcript's `textScale`) follow it.
    public static var userScale: CGFloat { scale }
    /// A style's size: the density's (`DensityTokens.textSize`, which follows its level and its
    /// own font size), times the user's text scale.
    private static func size(_ compactSize: CGFloat, _ comfortableSize: CGFloat) -> CGFloat {
        Metrics.tokens.textSize(compact: compactSize, comfortable: comfortableSize) * scale
    }
    /// The system font designs chrome uses.
    public enum Design: Hashable, Sendable {
        case `default`, monospaced, monospacedDigit
    }

    /// The system font of `design` at `size` and `weight`, made once per
    /// process and kept alive. Use it instead of a fresh `NSFont.systemFont`
    /// or `monospacedSystemFont` call in a computed property: a font made
    /// and dropped on every draw can come back nil (`CheckedFont`, #20557).
    public static func system(_ design: Design = .default, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        CheckedFont.system(design, size: size, weight: weight)
    }

    /// Tab titles, sidebar rows, palette results.
    public static var body: NSFont { system(.default, size: size(12, 13), weight: .regular) }
    /// Tab titles: `appearance.metrics.tabFontSize` (times the interface scale when it is on), else `body`.
    public static var tabTitle: NSFont {
        guard let points = DesignSettings.shared.overrides[.tabFontSize] else { return body }
        return system(.default, size: Metrics.scale(points), weight: .regular)
    }
    /// Selected or emphasized row titles.
    public static var bodyEmphasized: NSFont { system(.default, size: size(12, 13), weight: .medium) }
    /// Subtitles, shortcut hints, counts.
    public static var caption: NSFont { system(.default, size: size(10.5, 11), weight: .regular) }
    /// `caption` with tabular digits: a count that ticks (a download's bytes) keeps its width.
    public static var captionDigits: NSFont { system(.monospacedDigit, size: size(10.5, 11), weight: .regular) }
    /// Section headers (uppercase is not used; weight and color carry hierarchy).
    public static var header: NSFont { system(.default, size: size(11, 12), weight: .semibold) }
    /// Palette search field.
    public static var search: NSFont { system(.default, size: size(16, 18), weight: .regular) }
    /// Shortcut glyphs.
    public static var shortcut: NSFont { system(.monospaced, size: size(10.5, 11), weight: .medium) }
    /// Page titles in windows that introduce something (onboarding).
    public static var title: NSFont { system(.default, size: size(20, 22), weight: .semibold) }
    /// The line under a page title.
    public static var subtitle: NSFont { system(.default, size: size(13, 14), weight: .regular) }
}
