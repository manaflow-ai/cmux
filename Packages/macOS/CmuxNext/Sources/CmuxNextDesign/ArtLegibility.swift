/// Which text the window's glass keeps readable over background art (`appearance.glassLegibility`).
/// The glass's tint never goes below the least opacity at which these roles keep their contrast
/// over the art (``BackdropArtRange``), so this decides how much of the art shows. The live choice
/// lives on the theme scopes (``ThemeScope/artLegibility``).
public nonisolated enum ArtLegibility: String, CaseIterable, Sendable {
    /// Primary text at WCAG AA body contrast, as iOS glass does over a wallpaper: secondary and
    /// tertiary text may read below their contrast over the art's brightest or darkest parts, and
    /// much more of the art shows (Leo 2026-10-18: "IOS IOS").
    case primary
    /// Every text role at its contrast over any part of the art: denser glass.
    case all
}
