public import CoreGraphics
public import Foundation

/// The curved main pane (cx-rkgu, Leo 2026-10-10): the workspace content
/// is one rounded card beside the sidebar, as in Edge. Where it meets the
/// window's edges it takes the window's own edge and corners (Leo
/// 2026-10-13, one container level): a gutter there drew a second rounded
/// outline inside the window's, over wallpaper art most of all. Under
/// `appearance.sidebarSurface` separate, the chrome around the card
/// (sidebar, gutter, titlebar) is shaded a little darker so the curve reads
/// on the one surface; by default it shares the card's surface
/// (`SidebarSurface`). On by default to try; these are Debug Settings
/// tunables until a cmux.json key gets a settings slot.
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
        help: "Space between the curved main pane and the titlebar and the window edges. 0: the pane meets the window edge and takes its corners.",
        default: 0, range: 0...24, step: 0.5, unit: .points, code: "ChromeTunables.mainPaneGutter")
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
    /// Whether the workspace content is the curved main pane.
    public static var mainPaneCurved: Bool { ChromeTunables.mainPaneCurved.value }
    /// Inset of the main pane from the titlebar and window edges (beside
    /// the sidebar its row inset is the gap); 0 by default, so the pane
    /// meets the window edge and one outline shows there.
    public static var mainPaneGutter: CGFloat { mainPaneCurved ? scale(ChromeTunables.mainPaneGutter.value) : 0 }
    /// Corner radius of the main pane; 0 when it is edge to edge.
    public static var mainPaneCornerRadius: CGFloat { mainPaneCurved ? scale(ChromeTunables.mainPaneCornerRadius.value) : 0 }
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
        guard mainPaneCurved, ChromeTunables.mainPaneCornerRadius.override == nil else { return mainPaneCornerRadius }
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
        let separate = CGFloat(isDark ? ChromeTunables.mainPaneShadeDark.value : ChromeTunables.mainPaneShadeLight.value)
        // A pane outline or the sidebar's edge line parts them; both are already 0 under borders none.
        let lineSeparates = paneBorder != .none || sidebarBorderWidth > 0
        return DesignSettings.shared.sidebarSurface.chromeShade(separateShade: separate, lineSeparates: lineSeparates)
    }
}
