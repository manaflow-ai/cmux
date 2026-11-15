public import CoreGraphics
public import AppKit
public import Foundation
public import CmuxNextDesignTokens

/// The curved main pane (cx-rkgu, Leo 2026-10-10): the workspace content
/// sits inset in the window chrome as one rounded card, as in Edge. A
/// gutter of 0 (Debug Settings, 2026-10-14) is the flush opt-in: the pane
/// meets the window's edges and takes the window's own corners, so one
/// outline shows there instead of the gutter's second one. Under
/// `appearance.sidebarSurface` separate, the chrome around the card
/// (sidebar, gutter, titlebar) is shaded a little darker so the curve reads
/// on the one surface; by default it shares the card's surface
/// (`SidebarSurface`). On by default; `appearance.chromeStyle` turns it on
/// or off with the rest of a style, and these Debug Settings tunables
/// override it.
nonisolated extension ChromeTunables {
    public static let mainPaneCurved = Tunable<Bool>.toggle(
        "chrome.mainPane.curved", .sidebar, "Curved main pane",
        help: "Inset the workspace content as one rounded card in the window chrome (Edge style). Off: edge to edge.",
        default: true, code: "ChromeTunables.mainPaneCurved")
    public static let mainPaneCornerRadius = Tunable<CGFloat>.number(
        "chrome.mainPane.cornerRadius", .sidebar, "Main pane corner radius",
        help: "Corner radius of the curved main pane. Unset: concentric with the window (its corner radius less the gutter), or layout.paneCornerRadius when set, at most the window's.", default: 10, range: 0...24, step: 0.5, unit: .points,
        code: "ChromeTunables.mainPaneCornerRadius")
    public static let mainPaneGutter = Tunable<CGFloat>.number(
        "chrome.mainPane.gutter", .sidebar, "Main pane gutter",
        help: "Space between the curved main pane and the sidebar, the titlebar and the window edges. 0 (flush): the pane meets the window edge and takes its corners.",
        default: 6, range: 0...24, step: 0.5, unit: .points, code: "ChromeTunables.mainPaneGutter")
    public static let mainPaneShadeLight = Tunable<Double>.number(
        "chrome.mainPane.shadeLight", .sidebar, "Main pane chrome shade (light)",
        help: "Light themes: black over the chrome around the curved main pane, so the pane reads as a card.",
        default: 0.045, range: 0...0.4, step: 0.005, unit: .fraction, code: "ChromeTunables.mainPaneShadeLight")
    public static let mainPaneShadeDark = Tunable<Double>.number(
        "chrome.mainPane.shadeDark", .sidebar, "Main pane chrome shade (dark)",
        help: "Dark themes: black over the chrome around the curved main pane, so the pane reads as a card.",
        default: 0.28, range: 0...0.8, step: 0.01, unit: .fraction, code: "ChromeTunables.mainPaneShadeDark")

    static var mainPane: [TunableDescriptor] {
        [mainPaneCurved.descriptor, mainPaneCornerRadius.descriptor, mainPaneGutter.descriptor, mainPaneShadeLight.descriptor,
         mainPaneShadeDark.descriptor]
    }
}

extension Metrics {
    /// Whether the workspace content is the curved main pane: a Debug
    /// Settings override, else `appearance.chromeStyle`, else the default.
    public static var mainPaneCurved: Bool {
        let tunable = ChromeTunables.mainPaneCurved
        // The flush corner (`chrome.cornerFlush`) draws the card under any chrome style; a Debug override still wins.
        let flush: Bool? = CornerFlush.current.isOn ? true : nil
        return tunable.override ?? flush ?? DesignSettings.shared.chromeStyle.curvedMainPane ?? tunable.defaultValue
    }
    /// The card's edge is the sidebar's seam, so the sidebar's edge line stays in the titlebar band and its hover
    /// and drag glow light nothing: the curved main pane, where the flush corner counts only when picked in Debug
    /// Settings (``CornerFlush/isChosen``). Since #40282 made the flush corner the default, ``mainPaneCurved`` is
    /// true under the stock `flat` style too, and the sidebar lost its full-height line and its resize highlight.
    /// Leo, 2026-11-12: "you've, like, slightly regressed the border thing, the border divider. And then there's,
    /// like, no more drag divider highlight or anything like that." The default folder tab keeps both.
    public static var cardEdgeIsSidebarSeam: Bool {
        let tunable = ChromeTunables.mainPaneCurved
        let flush: Bool? = CornerFlush.isChosen ? true : nil
        return tunable.override ?? flush ?? DesignSettings.shared.chromeStyle.curvedMainPane ?? tunable.defaultValue
    }
    /// Floating panes (`appearance.chromeStyle` floating): every pane is its
    /// own card, tab strip included, left unshaded on the shaded chrome
    /// (`MainPaneChromeShadeView`); the main pane itself draws no card.
    public static var floatingPanes: Bool { mainPaneCurved && DesignSettings.shared.chromeStyle.floatingPanes }
    /// Floating panes draw no focus ring (no outline anywhere; the other
    /// panes' dim marks focus), unless the system asks for more contrast.
    public static var floatingPanesHideFocusRing: Bool {
        floatingPanes && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }
    /// Inset of the main pane from the sidebar, titlebar and window edges;
    /// 0 when the pane is edge to edge, or the flush opt-in (a Debug
    /// Settings gutter of 0), where the pane meets the window edge and one
    /// outline shows there. Floating panes: the pane padding
    /// (unless Debug Settings set the gutter), so the gap at the edges and
    /// beside the sidebar (gutter plus padding) equals the gap between two
    /// panes (twice the padding; the layout leaves no divider gap then).
    public static var mainPaneGutter: CGFloat {
        guard mainPaneCurved else { return 0 }
        if floatingPanes, ChromeTunables.mainPaneGutter.override == nil { return panePadding }
        if CornerFlush.current.isOn, ChromeTunables.mainPaneGutter.override == nil { return CornerFlush.current.gap }
        return scale(ChromeTunables.mainPaneGutter.value)
    }
    /// Corner radius of the main pane; 0 when it is edge to edge or its
    /// panes float (each pane rounds its own card).
    public static var mainPaneCornerRadius: CGFloat {
        guard mainPaneCurved, !floatingPanes || ChromeTunables.mainPaneCornerRadius.override != nil else { return 0 }
        return ChromeTunables.mainPaneCornerRadius.override.map(scale) ?? cornerRadius
    }
    /// Corner radius of the main pane in a window whose own corners have `windowCornerRadius`
    /// (``windowConcentricCornerRadius(windowCornerRadius:edgeInset:setting:)``): concentric with
    /// the window across the gutter by default, the radius `layout.paneCornerRadius` sets when it
    /// is set. Lawrence 2026-11-07: "we are not concentric with macos window ... make it all
    /// concentric with macos windows by default (but still configurable)"; the 8 pt default card
    /// 6 pt inside the 16 pt window left a gap that widened toward the corner.
    /// Without a gutter the pane's corners sit just inside the window's
    /// lit rim (``windowEdgeInset(_:in:)``), concentric with it; under a
    /// standard titlebar strip the pane's top corners sit below it, against
    /// the window's straight side, so the pane is square there (the window
    /// still rounds its own corners). A Debug Settings override wins.
    ///
    /// With no radius the person set and no outline, the card a pill strip nests in rounds from its
    /// tabs instead (Lawrence 2026-11-11, "same roundness as chrome";
    /// ``chromeRowConcentricCardRadius(windowCornerRadius:)``): 10 pt at Compact, as before, and at
    /// most the window's own radius. The flush corner keeps its window-concentric card: its strip sits
    /// on the frame above the card, not inside it.
    public static func mainPaneCornerRadius(windowCornerRadius: CGFloat) -> CGFloat {
        guard mainPaneCurved, !floatingPanes, ChromeTunables.mainPaneCornerRadius.override == nil else { return mainPaneCornerRadius }
        if let set = ChromeLabToken.cardRadius.value { return set }
        // The flush corner: concentric with the window across its 4 pt gap (12 pt in a 16 pt window).
        let flush = CornerFlush.current
        if flush.isOn { return windowCornerRadius > 0 ? max(0, windowCornerRadius - flush.gap) : flush.cardRadius }
        let gutter = mainPaneGutter
        if gutter == 0 { return DesignSettings.shared.titlebar == .standard ? 0 : max(0, windowCornerRadius - PaneTabRowRim.height) }
        // Chrome's tab radius sizes the card the strip nests in, so the first pill stays concentric with it.
        if mainPaneRoundsFromTabs { return chromeRowConcentricCardRadius(windowCornerRadius: windowCornerRadius) }
        return windowConcentricCornerRadius(windowCornerRadius: windowCornerRadius, edgeInset: max(gutter, PaneTabRowRim.height),
                                            setting: DesignSettings.shared.paneChrome.cornerRadius.map(scale))
    }

    /// Whether the curved main pane rounds from its tabs (``chromeRowConcentricCardRadius(windowCornerRadius:)``):
    /// Chrome's tab radius applies (``usesChromeRowCorner``), the card has a gutter, no outline and no
    /// Debug Settings radius, and the flush corner is off (its strip sits on the frame, not in the card).
    public static var mainPaneRoundsFromTabs: Bool {
        guard usesChromeRowCorner, mainPaneCurved, ChromeTunables.mainPaneCornerRadius.override == nil,
              !CornerFlush.current.isOn, paneBorder == .none else { return false }
        return mainPaneGutter > 0
    }

    /// The radius of the card a top-row pill strip nests in, concentric with its tabs: Chrome's tab
    /// radius (``chromeRowCornerRadius(height:)`` at ``tabHeight``) plus the pill's inset from the
    /// card's corner (``tabStripCardInset``), at most the window's radius (the titled window's when
    /// `windowCornerRadius` is 0), so the card never rounds more than the window it sits in.
    public static func chromeRowConcentricCardRadius(windowCornerRadius: CGFloat) -> CGFloat {
        let window = windowCornerRadius > 0 ? windowCornerRadius : standardWindowCornerRadius
        return min(chromeRowCornerRadius(height: tabHeight) + tabStripCardInset, window)
    }

    /// The radius of a card `edgeInset` points inside a window whose corners have
    /// `windowCornerRadius`, equal on every side it meets: the window's radius less the inset, so the
    /// two curves share a center (``ConcentricCorners``). A square window (fullscreen, borderless,
    /// radius 0) keeps the titled window's radius (``standardWindowCornerRadius``), so a fullscreen
    /// toggle reshapes nothing. A `setting` (`layout.paneCornerRadius`) wins, at most the window's
    /// own radius.
    ///
    /// ```swift
    /// Metrics.windowConcentricCornerRadius(windowCornerRadius: 16, edgeInset: 6, setting: nil) // 10
    /// Metrics.windowConcentricCornerRadius(windowCornerRadius: 16, edgeInset: 6, setting: 20)  // 16
    /// ```
    public static func windowConcentricCornerRadius(windowCornerRadius: CGFloat, edgeInset: CGFloat, setting: CGFloat?) -> CGFloat {
        if let setting { return windowCornerRadius > 0 ? min(max(0, setting), windowCornerRadius) : max(0, setting) }
        let window = windowCornerRadius > 0 ? windowCornerRadius : standardWindowCornerRadius
        return ConcentricCorners(outer: window, padding: 0).nested(in: window, inset: edgeInset)
    }
    /// How far the main pane stays inside a window edge it meets: `inset`, and at least the window's
    /// lit rim (``PaneTabRowRim/height``, the edge highlight the window's glass draws just inside its
    /// frame) in a titled window that is not fullscreen, so the rim runs unbroken over the main pane
    /// as it does over the sidebar. Leo 2026-11-07, on a pane that met the window's edge: "the window
    /// at the edges, it just doesn't show through ... this doesn't look cohesive". A fullscreen or
    /// borderless window has no rim.
    public static func windowEdgeInset(_ inset: CGFloat, in window: NSWindow?) -> CGFloat {
        guard let window, window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else { return inset }
        return max(inset, PaneTabRowRim.height)
    }
    /// Black's alpha over the chrome around the main pane (the sidebar, the titlebar and the tab row
    /// around the content card): ``mainPaneChromeShadeBase(isDark:)`` scaled by ``titleAreaShadeScale``. Leo,
    /// 2026-11-11, on the title area: "the contrast, I guess it's fine, but I feel like it may be too intense for
    /// some people, so it needs to be adjustable." At most 1.
    public static func mainPaneChromeShade(isDark: Bool) -> CGFloat {
        let base = mainPaneChromeShadeBase(isDark: isDark)
        let scale = titleAreaShadeScale
        return scale == 1 ? base : min(1, max(0, base * scale))
    }

    /// The least chrome shade under which a selected folder tab in the content's surface still reads
    /// (``Palette/folderTabFill``): Subtle Tone's light frame (0.045 × ``TitleAreaTone/subtleShare``) still
    /// clears it at a title area contrast of 0.5; under it the tab keeps the selection fill.
    public static let folderTabMinimumShade: CGFloat = 0.011

    /// How strongly the tab row's divider draws (a share of `Palette.separator`): the line takes over from the
    /// tone as `appearance.titleAreaContrast` drops, so the tab row stays marked at any contrast. 0 at a
    /// contrast of 1 or more (the shipped look, no line), 1 at a contrast of 0 (one colour: the line and the
    /// selected tab's pill are the only separation). Leo, 2026-11-12: "THERE IS THE DIVIDER THERE ARE WAYS TO
    /// MAKE THE 'BACKGROUND' LESS CONTRAST THAN IT DOES NOW".
    public static var tabRowDividerStrength: CGFloat {
        min(1, max(0, 1 - titleAreaShadeScale))
    }

    /// The share of ``mainPaneChromeShadeBase(isDark:)`` the chrome draws. On the default flush corner's frame
    /// (``CornerFlush``) `appearance.titleAreaTone` decides it: 0 under One Color (the default, Lawrence's single
    /// colour), ``TitleAreaTone/subtleShare`` × `appearance.titleAreaContrast` under Subtle Tone. Every other
    /// chrome style (floating, blocks, card and the explicit two-tone style) keeps its own shade, scaled by the
    /// contrast alone, so the default tone never flattens a look the user picked. Leo, 2026-11-12: "since lawrence
    /// wanted the default to be mono ish (the tab bar the side bar the main view kinda the same-ish) we can make that
    /// the default... but i still think at least a subtle toning might be a bit nice."
    public static var titleAreaShadeScale: CGFloat {
        let design = DesignSettings.shared
        guard CornerFlush.current.isOn else { return design.titleAreaContrast }
        return design.titleAreaTone == .oneColor ? 0 : TitleAreaTone.subtleShare * design.titleAreaContrast
    }

    /// The chrome's shade before `appearance.titleAreaContrast`: the shade of the
    /// separate look only under `appearance.sidebarSurface` separate (the
    /// default shares the pane's surface, `SidebarSurface`); 0 when the pane
    /// is edge to edge.
    public static func mainPaneChromeShadeBase(isDark: Bool) -> CGFloat {
        guard mainPaneCurved else { return 0 }
        // The flush corner shades its frame so the card reads on the one surface.
        if CornerFlush.current.isOn { return CornerFlush.current.shade(isDark: isDark) }
        let style = DesignSettings.shared.chromeStyle
        let tunable = isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight
        let separate = tunable.override.map { CGFloat($0) } ?? style.separateShade(isDark: isDark) ?? CGFloat(tunable.defaultValue)
        // A pane outline or the sidebar's edge line parts them; both are already 0 under borders none.
        let lineSeparates = paneBorder != .none || sidebarBorderWidth > 0
        return DesignSettings.shared.sidebarSurface.chromeShade(separateShade: separate, lineSeparates: lineSeparates,
                                                                borderlessStep: style.borderlessStep ?? SidebarSurface.borderlessStep)
    }
}
