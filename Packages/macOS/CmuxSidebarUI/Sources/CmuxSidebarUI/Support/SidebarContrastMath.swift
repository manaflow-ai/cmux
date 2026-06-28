public import AppKit
public import SwiftUI
import Foundation

/// WCAG-style readability primitives for sidebar/titlebar chrome: relative
/// luminance, contrast ratio, alpha compositing, and the readable foreground
/// color/scheme for a given background.
///
/// Lifted byte-identically from the app target's `SidebarAppearanceSupport`
/// `cmux*` free functions so the pure color math lives with the sidebar UI
/// package instead of the `ContentView` god cluster. The app keeps one-line
/// `cmux*` forwarders into these members as a transitional seam. Pure compute
/// on `NSColor`/`Color`/`CGFloat`; no Tab/TabManager/Workspace reach.
public enum SidebarContrastMath {
    /// Returns whether white or black text reads better on `backgroundColor`,
    /// expressed as the `ColorScheme` whose default foreground wins on contrast.
    public static func readableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
        let backgroundLuminance = relativeLuminance(backgroundColor)
        let whiteContrast = contrastRatio(backgroundLuminance, 1.0)
        let blackContrast = contrastRatio(backgroundLuminance, 0.0)
        return whiteContrast >= blackContrast ? .dark : .light
    }

    /// The most readable foreground color (white or black) for `backgroundColor`,
    /// at the given `opacity` (clamped to `0...1`).
    public static func readableForegroundNSColor(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor {
        let clampedOpacity = max(0, min(opacity, 1))
        return readableForegroundBaseColor(on: backgroundColor)
            .withAlphaComponent(clampedOpacity)
    }

    /// Returns `preferredColor` when it already meets `minimumContrast` against
    /// `backgroundColor` (compositing a translucent preferred color over the
    /// background first), otherwise the readable white/black foreground at the
    /// preferred color's alpha.
    public static func readableForegroundNSColor(
        preferred preferredColor: NSColor,
        on backgroundColor: NSColor,
        minimumContrast: CGFloat = 4.5
    ) -> NSColor {
        let foregroundForComparison = preferredColor.alphaComponent < 1
            ? compositedNSColor(preferredColor, over: backgroundColor)
            : preferredColor
        guard contrastRatio(foreground: foregroundForComparison, background: backgroundColor) < minimumContrast else {
            return preferredColor
        }
        return readableForegroundNSColor(on: backgroundColor, opacity: preferredColor.alphaComponent)
    }

    /// Alpha-composites `foreground` over `background` in sRGB, returning an
    /// opaque color.
    public static func compositedNSColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let fg = foreground.usingColorSpace(.sRGB) ?? foreground
        let bg = background.usingColorSpace(.sRGB) ?? background
        var foregroundRed: CGFloat = 0
        var foregroundGreen: CGFloat = 0
        var foregroundBlue: CGFloat = 0
        var foregroundAlpha: CGFloat = 0
        var backgroundRed: CGFloat = 0
        var backgroundGreen: CGFloat = 0
        var backgroundBlue: CGFloat = 0
        var backgroundAlpha: CGFloat = 0
        fg.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha)
        bg.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
        _ = backgroundAlpha

        let alpha = max(0, min(foregroundAlpha, 1))
        return NSColor(
            srgbRed: foregroundRed * alpha + backgroundRed * (1 - alpha),
            green: foregroundGreen * alpha + backgroundGreen * (1 - alpha),
            blue: foregroundBlue * alpha + backgroundBlue * (1 - alpha),
            alpha: 1
        )
    }

    /// The WCAG contrast ratio between two colors' relative luminances.
    public static func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
        contrastRatio(
            relativeLuminance(foreground),
            relativeLuminance(background)
        )
    }

    private static func readableForegroundBaseColor(on backgroundColor: NSColor) -> NSColor {
        readableColorScheme(for: backgroundColor) == .dark ? .white : .black
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        _ = alpha

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    private static func contrastRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let lighter = max(lhs, rhs)
        let darker = min(lhs, rhs)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
