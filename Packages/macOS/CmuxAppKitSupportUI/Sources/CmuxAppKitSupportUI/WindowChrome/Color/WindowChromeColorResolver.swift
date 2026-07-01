public import AppKit
public import SwiftUI

/// Resolves color math used by window chrome, titlebar, and backdrop policy.
public struct WindowChromeColorResolver: Sendable {
    /// Creates a color resolver.
    public init() {}

    /// Returns a separator color readable against the given chrome background.
    public func separatorColor(forChromeBackground chrome: NSColor) -> NSColor {
        let srgb = chrome.usingColorSpace(.sRGB) ?? chrome
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        let isLight = luminance > 0.5
        let amount: CGFloat = isLight ? -0.12 : 0.16
        let separatorAlpha: CGFloat = isLight ? 0.26 : 0.36
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
