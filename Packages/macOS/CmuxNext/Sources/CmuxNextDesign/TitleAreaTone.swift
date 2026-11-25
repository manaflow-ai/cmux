public import CoreGraphics

/// `appearance.titleAreaTone`: whether the chrome around the content (the titlebar, the tab row and the
/// sidebar) is the content's colour or a subtle tone apart from it, on the default flush-corner frame
/// (``Metrics/titleAreaShadeScale``). Leo, 2026-11-12: "since lawrence wanted the default to be mono ish (the tab
/// bar the side bar the main view kinda the same-ish) we can make that the default... but i still think at least a
/// subtle toning might be a bit nice."
///
/// - `oneColor` (the default): no shade, so the chrome is the content's colour; the dividers
///   (`Palette.chromeDivider`: the sidebar's full-height edge line, the split panes' lines and the tab row's divider
///   at full ``Metrics/tabRowDividerStrength``) and the selected tab's pill (`Palette.selectionFill`) separate.
/// - `subtleTone`: the frame takes ``subtleShare`` of the flush corner's shade, scaled by
///   `appearance.titleAreaContrast`, and the selected tab is a folder tab in the content's glass that opens into it;
///   the dividers stay, the tab row's at the strength the tone leaves it.
///
/// The switch is live: the shade, the corner, the divider and every tab follow in one pass
/// (`WindowRootView.observeMainPane`, `ThemeStore.repaintAll`).
public nonisolated enum TitleAreaTone: String, Sendable, CaseIterable, Codable {
    case oneColor
    case subtleTone

    /// Subtle Tone's share of the flush corner's frame shade at a title area contrast of 1 (the older two tones
    /// drew all of it): picked from the chrome-divider gallery (cmux#41640), where it parts the sidebar and the tab
    /// row from the content in light and dark without reading as a second surface. Contrast 2 is the older shade.
    public static let subtleShare: CGFloat = 0.5
}
