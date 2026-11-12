/// `appearance.titleAreaTone`: whether the chrome around the content (the titlebar, the tab row and the
/// sidebar) is its own tone or the content's colour. Leo, 2026-11-12: "Lawrence doesn't want it as a
/// default, so we also need to be able to, like, just be able to toggle that back and forth really well."
///
/// - `oneColor` (the default): no shade, so the chrome is the content's colour; the dividers
///   (`Palette.chromeDivider`: the sidebar's edge line, the split panes' lines and the tab row's divider at full
///   ``Metrics/tabRowDividerStrength``) and the selected tab's pill (`Palette.selectionFill`) are the separation.
///   Leo, 2026-11-12: "he said he wanted to keep the default without the two tone for some reason :x anyways how
///   about the divider tho? we still want to keep that... across most panes by default."
/// - `twoTone`: the chrome is shaded apart from the content by `appearance.titleAreaContrast`
///   (``Metrics/mainPaneChromeShade(isDark:)``), and the selected tab is a folder tab in the content's glass
///   that opens into it.
///
/// The switch is live: the shade, the corner, the divider and every tab follow in one pass
/// (`WindowRootView.observeMainPane`, `ThemeStore.repaintAll`).
public nonisolated enum TitleAreaTone: String, Sendable, CaseIterable, Codable {
    case twoTone
    case oneColor
}
