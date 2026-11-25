public import CmuxTheme

/// The fill of a grouped form's rows (``Palette/groupFill``), as macOS 26 draws an info panel's groups
/// (Messages' and Contacts' info, System Settings' forms; Lawrence 2026-11-23).
extension ThemeTokens {
    /// The theme's text color, faint (8% on a dark theme, 6% on a light one, so a group reads as one), on
    /// the panel's surface. It is a resting fill: unlike ``hoverFill`` the pointer does not change it, and the
    /// chrome's emphasis does not scale it. A theme whose secondary text would fall under 4.5:1 on it over the
    /// window background gets the strongest fill that keeps 4.5:1.
    nonisolated public var groupFill: ThemeRGB {
        let ground = windowBackground.withAlpha(1), secondary = textSecondary.composited(over: ground)
        var alpha = isDark ? 0.08 : 0.06
        while alpha > 0, secondary.contrast(with: textPrimary.withAlpha(alpha).composited(over: ground)) < ThemeTokens.minimumTextContrast {
            alpha -= 0.005
        }
        return textPrimary.withAlpha(max(alpha, 0))
    }
}
