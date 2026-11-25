public import CmuxTheme

/// The fill of a grouped form's rows (``Palette/groupFill``), as macOS 26 draws an info panel's groups
/// (Messages' and Contacts' info, System Settings' forms; Lawrence 2026-11-23).
extension ThemeTokens {
    /// The theme's text color, faint, on the panel's surface. It is a resting fill: unlike
    /// ``hoverFill`` it is not something the pointer changes, and the chrome's emphasis does not scale it.
    nonisolated public var groupFill: ThemeRGB { textPrimary.withAlpha(isDark ? 0.06 : 0.045) }
}
