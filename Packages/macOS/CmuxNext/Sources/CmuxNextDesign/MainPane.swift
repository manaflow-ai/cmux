public import CoreGraphics
import AppKit
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
        help: "Corner radius of the curved main pane. Unset: the window's corner radius less the gutter (square in fullscreen without a gutter, else 8).", default: 8, range: 0...24, step: 0.5, unit: .points,
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
        return tunable.override ?? DesignSettings.shared.chromeStyle.curvedMainPane ?? tunable.defaultValue
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
        return scale(ChromeTunables.mainPaneGutter.value)
    }
    /// Corner radius of the main pane; 0 when it is edge to edge or its
    /// panes float (each pane rounds its own card).
    public static var mainPaneCornerRadius: CGFloat {
        guard mainPaneCurved, !floatingPanes || ChromeTunables.mainPaneCornerRadius.override != nil else { return 0 }
        return scale(ChromeTunables.mainPaneCornerRadius.value)
    }
    /// Corner radius of the main pane in a window whose own corners have
    /// `windowCornerRadius`: concentric with them (the window radius less
    /// the gutter). Without a gutter the pane's corners at the window's are
    /// the window's own, so the two are one outline; a square window
    /// (fullscreen) gets a square pane, rounding only at real edges. Under a
    /// standard titlebar strip the pane's top corners sit below it, against
    /// the window's straight side, so the pane is square too (the window
    /// still rounds its own corners). A Debug
    /// Settings override wins; with a gutter in fullscreen it is
    /// `mainPaneCornerRadius`.
    public static func mainPaneCornerRadius(windowCornerRadius: CGFloat) -> CGFloat {
        guard mainPaneCurved, !floatingPanes, ChromeTunables.mainPaneCornerRadius.override == nil else { return mainPaneCornerRadius }
        let gutter = mainPaneGutter
        if gutter == 0 { return DesignSettings.shared.titlebar == .standard ? 0 : windowCornerRadius }
        return windowCornerRadius > 0 ? max(0, windowCornerRadius - gutter) : mainPaneCornerRadius
    }
    /// Black's alpha over the chrome around the main pane: the shade of the
    /// separate look only under `appearance.sidebarSurface` separate (the
    /// default shares the pane's surface, `SidebarSurface`); 0 when the pane
    /// is edge to edge.
    public static func mainPaneChromeShade(isDark: Bool) -> CGFloat {
        guard mainPaneCurved else { return 0 }
        let style = DesignSettings.shared.chromeStyle
        let tunable = isDark ? ChromeTunables.mainPaneShadeDark : ChromeTunables.mainPaneShadeLight
        let separate = tunable.override.map { CGFloat($0) } ?? style.separateShade(isDark: isDark) ?? CGFloat(tunable.defaultValue)
        // A pane outline or the sidebar's edge line parts them; both are already 0 under borders none.
        let lineSeparates = paneBorder != .none || sidebarBorderWidth > 0
        return DesignSettings.shared.sidebarSurface.chromeShade(separateShade: separate, lineSeparates: lineSeparates,
                                                                borderlessStep: style.borderlessStep ?? SidebarSurface.borderlessStep)
    }
}
