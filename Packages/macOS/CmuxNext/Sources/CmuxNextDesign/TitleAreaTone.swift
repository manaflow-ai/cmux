/// `appearance.titleAreaTone`: whether the chrome around the content (the titlebar, the tab row and the
/// sidebar) is its own tone or the content's colour. Leo, 2026-11-12: "Lawrence doesn't want it as a
/// default, so we also need to be able to, like, just be able to toggle that back and forth really well."
///
/// - `twoTone` (the default): the chrome is shaded apart from the content by
///   `appearance.titleAreaContrast` (``Metrics/mainPaneChromeShade(isDark:)``), and the selected tab is a
///   folder tab in the content's glass that opens into it.
/// - `oneColor`: no shade, so the chrome is the content's colour; the tab row's divider
///   (``Metrics/tabRowDividerStrength``) at full strength and the selected tab's pill (`Palette.selectionFill`)
///   are the only separation.
///
/// The switch is live: the shade, the corner, the divider and every tab follow in one pass
/// (`WindowRootView.observeMainPane`, `ThemeStore.repaintAll`).
public nonisolated enum TitleAreaTone: String, Sendable, CaseIterable, Codable {
    case twoTone
    case oneColor
}
