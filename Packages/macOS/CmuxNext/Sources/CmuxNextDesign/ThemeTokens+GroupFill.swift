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
        // Whole half-percent steps, so repeated subtraction does not drift under a step (0.04999…).
        var steps = Int((groupFillTarget * 200).rounded())
        while steps > 0, secondary.contrast(with: textPrimary.withAlpha(Double(steps) / 200).composited(over: ground)) < floor {
            steps -= 1
        }
        return textPrimary.withAlpha(Double(steps) / 200)
    }

    /// The edge of a grouped form's rows (``Palette/groupStroke``): a hairline (``separator``) where 4.5:1
    /// held ``groupFill`` under its 8% or 6%, so the group still reads as one; clear where the fill is whole.
    ///
    /// A dark popup is lifted until secondary text on a hovered row just keeps 4.5:1
    /// (``opaqueOverlayFill(lift:)``), so its groups take about 5%, weaker than a group should read; the
    /// hairline sets them apart without taking any contrast from their text.
    nonisolated public var groupStroke: ThemeRGB {
        groupFill.alpha < groupFillTarget - 0.001 ? separator : separator.withAlpha(0)
    }

    /// The group fill's alpha when text contrast allows it: 8% of the text color dark, 6% light.
    nonisolated var groupFillTarget: Double { isDark ? 0.08 : 0.06 }
}
