public import AppKit
public import SwiftUI

/// Resolves color math used by window chrome, titlebar, and backdrop policy.
public struct WindowChromeColorResolver: Sendable {
    /// Creates a color resolver.
    public init() {}

    /// Returns a separator color readable against the given chrome background.
    ///
    /// - Parameter increaseContrast: The macOS Increase Contrast setting;
    ///   when on, the separator steps further from the background and is
    ///   less transparent so pane outlines and tab-bar edges stay visible.
    public func separatorColor(
        forChromeBackground chrome: NSColor,
        increaseContrast: Bool = false
    ) -> NSColor {
        let srgb = chrome.usingColorSpace(.sRGB) ?? chrome
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        let isLight = luminance > 0.5
        // Asymmetric because sRGB gamma compresses a fixed RGB step far more
        // near white than near black. These deltas put both sides at CIE
        // dL* ~7 against their own background once composited.
        // Increase Contrast: a larger step at higher opacity on both sides.
        let amount: CGFloat
        let separatorAlpha: CGFloat
        if increaseContrast {
            amount = isLight ? -0.55 : 0.40
            separatorAlpha = isLight ? 0.55 : 0.65
        } else {
            amount = isLight ? -0.30 : 0.16
            separatorAlpha = isLight ? 0.26 : 0.36
        }
        return NSColor(
            red: min(1.0, max(0.0, red + amount)),
            green: min(1.0, max(0.0, green + amount)),
            blue: min(1.0, max(0.0, blue + amount)),
            alpha: separatorAlpha
        )
    }

    /// Returns `foreground` composited over `background` in sRGB.
    public func compositedColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let foregroundColor = foreground.usingColorSpace(.sRGB) ?? foreground
        let backgroundColor = background.usingColorSpace(.sRGB) ?? background
        var foregroundRed: CGFloat = 0
        var foregroundGreen: CGFloat = 0
        var foregroundBlue: CGFloat = 0
        var foregroundAlpha: CGFloat = 0
        var backgroundRed: CGFloat = 0
        var backgroundGreen: CGFloat = 0
        var backgroundBlue: CGFloat = 0
        var backgroundAlpha: CGFloat = 0
        foregroundColor.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha)
        backgroundColor.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
        _ = backgroundAlpha

        let alpha = max(0, min(foregroundAlpha, 1))
        return NSColor(
            srgbRed: foregroundRed * alpha + backgroundRed * (1 - alpha),
            green: foregroundGreen * alpha + backgroundGreen * (1 - alpha),
            blue: foregroundBlue * alpha + backgroundBlue * (1 - alpha),
            alpha: 1
        )
    }

    /// Returns `foreground` with just enough extra opacity to reach
    /// `minimumContrast` (a WCAG contrast ratio) once composited over
    /// `background`.
    ///
    /// Secondary chrome text is the label color at reduced opacity, which is
    /// tuned for neutral backgrounds. Over a saturated mid-tone terminal
    /// theme the same opacity can fall to about 2.6:1. A color that already
    /// meets the floor comes back unchanged, so neutral themes keep the
    /// system look; one that cannot reach it comes back fully opaque.
    public func contrastFloored(
        _ foreground: NSColor,
        over background: NSColor,
        minimumContrast: CGFloat
    ) -> NSColor {
        let color = foreground.usingColorSpace(.sRGB) ?? foreground
        let backgroundLuminance = relativeLuminance(compositedColor(background, over: .black))
        func contrast(atAlpha alpha: CGFloat) -> CGFloat {
            let composited = compositedColor(color.withAlphaComponent(alpha), over: background)
            return contrastRatio(relativeLuminance(composited), backgroundLuminance)
        }
        let startAlpha = color.alphaComponent
        guard contrast(atAlpha: startAlpha) < minimumContrast else { return foreground }
        guard contrast(atAlpha: 1) >= minimumContrast else { return color.withAlphaComponent(1) }
        var low = startAlpha
        var high: CGFloat = 1
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if contrast(atAlpha: mid) >= minimumContrast { high = mid } else { low = mid }
        }
        return color.withAlphaComponent(high)
    }

    /// Returns the WCAG contrast ratio between two opaque colors.
    public func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        contrastRatio(relativeLuminance(lhs), relativeLuminance(rhs))
    }

    /// Returns the color scheme with stronger contrast against `backgroundColor`.
    public func readableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
        let backgroundLuminance = relativeLuminance(backgroundColor)
        let whiteContrast = contrastRatio(backgroundLuminance, 1.0)
        let blackContrast = contrastRatio(backgroundLuminance, 0.0)
        return whiteContrast >= blackContrast ? .dark : .light
    }

    private func contrastRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let lighter = max(lhs, rhs)
        let darker = min(lhs, rhs)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        _ = alpha

        let linearizedRed = linearized(red)
        let linearizedGreen = linearized(green)
        let linearizedBlue = linearized(blue)
        return 0.2126 * linearizedRed + 0.7152 * linearizedGreen + 0.0722 * linearizedBlue
    }

    private func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }
}
