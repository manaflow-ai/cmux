import Foundation

/// What the selection fill takes (`appearance.selection`): the selected sidebar row, tab and list pill.
///
/// ``accent`` (the default) is today's rule: the accent's tint when `appearance.accent` or the theme
/// names one, else the neutral fill. ``neutral`` keeps the neutral gray card (the foreground at a low
/// alpha) whatever the accent, so a look can keep a blue Send button and links with a gray selected
/// row, as the Codex desktop app draws its sidebar.
public enum ThemeSelection: String, CaseIterable, Hashable, Sendable {
    case accent, neutral
}
