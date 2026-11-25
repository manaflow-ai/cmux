public import CmuxTheme
import CmuxNextDesignTokens

/// The fill of a grouped form's rows (``Palette/groupFill``), as macOS 26 draws an info panel's groups
/// (Messages' and Contacts' info, System Settings' forms; Lawrence 2026-11-23).
extension ThemeTokens {
    /// The theme's text color, faint (up to 8% on a dark theme, 6% on a light one, so a group reads as one),
    /// on the popup surface it sits on (``opaqueOverlayFill(lift:)``). It is a resting fill: unlike
    /// ``hoverFill`` the pointer does not change it, and the chrome's emphasis does not scale it. It is the
    /// strongest fill up to that where secondary text keeps 4.5:1 on it, never weaker than the surface allows.
    nonisolated public var groupFill: ThemeRGB {
        // glass-opaque-allow: reads the popup surface only to measure text contrast; the group fill it returns is translucent.
        groupFill(on: opaqueOverlayFill(lift: ChromeTunables.opaqueOverlayLift.value))
    }

    /// ``groupFill`` on `surface`: the strongest of 8% (dark) or 6% (light) of the text color, in 0.5% steps,
    /// on which secondary text keeps 4.5:1, or keeps what it has on the bare surface when that is less.
    nonisolated func groupFill(on surface: ThemeRGB) -> ThemeRGB {
        let ground = surface.withAlpha(1)
        let secondary = textSecondary.composited(over: ground)
        let floor = min(ThemeTokens.minimumTextContrast, secondary.contrast(with: ground))
        var alpha = isDark ? 0.08 : 0.06
        while alpha > 0, secondary.contrast(with: textPrimary.withAlpha(alpha).composited(over: ground)) < floor {
            alpha -= 0.005
        }
        return textPrimary.withAlpha(max(alpha, 0))
    }
}
