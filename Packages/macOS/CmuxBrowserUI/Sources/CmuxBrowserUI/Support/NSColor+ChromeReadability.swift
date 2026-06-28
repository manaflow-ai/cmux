import AppKit
import SwiftUI

/// Color-scheme and compositing math the browser chrome derives its readable
/// foreground and pill colors from. Kept package-local (mirroring the per-package
/// appearance helpers in `CmuxSidebarUI`) so `BrowserChromeStyle` resolves without
/// reaching into the app target; the app keeps its own `cmuxReadableColorScheme`/
/// `cmuxCompositedNSColor` free functions until a later consolidation slice.
extension NSColor {
    /// The color scheme (`.dark`/`.light`) whose default foreground reads most
    /// legibly against this color used as a background.
    var readableColorScheme: ColorScheme {
        let backgroundLuminance = relativeLuminance
        let whiteContrast = Self.contrastRatio(backgroundLuminance, 1.0)
        let blackContrast = Self.contrastRatio(backgroundLuminance, 0.0)
        return whiteContrast >= blackContrast ? .dark : .light
    }

    /// Alpha-composites this color over `background`, returning an opaque sRGB
    /// color (the source-over result with the receiver's alpha as coverage).
    func composited(over background: NSColor) -> NSColor {
        let fg = usingColorSpace(.sRGB) ?? self
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

    private var relativeLuminance: CGFloat {
        let srgb = usingColorSpace(.sRGB) ?? self
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
