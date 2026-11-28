#if canImport(UIKit)
import UIKit

/// CSS variable overrides pushed into the markdown shell so GitHub's
/// stylesheet blends with the surrounding surface. Mirrors the macOS
/// `MarkdownWebTheme`, resolved from the iOS system background instead of the
/// terminal background.
struct MarkdownWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let mutedBackground: String
    let neutralMutedBackground: String
    let border: String
    let mutedBorder: String

    static func resolve(isDark: Bool) -> MarkdownWebTheme {
        let traits = UITraitCollection(userInterfaceStyle: isDark ? .dark : .light)
        let base = UIColor.systemBackground.resolvedColor(with: traits).markdownOpaqueSRGB
        let overlay: UIColor = isDark ? .white : .black
        let muted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.09 : 1.06,
            of: overlay
        )
        let neutralMuted = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.35 : 1.20,
            of: overlay
        )
        let border = base.markdownThemeOverlay(
            targetContrast: isDark ? 1.92 : 1.43,
            of: overlay
        )
        return MarkdownWebTheme(
            isDark: isDark,
            background: "transparent",
            mutedBackground: muted.markdownCSSColor,
            neutralMutedBackground: neutralMuted.markdownCSSColor,
            border: border.markdownCSSColor,
            mutedBorder: border.markdownWithAlphaScaled(0.70).markdownCSSColor
        )
    }
}

extension UIColor {
    var markdownOpaqueSRGB: UIColor {
        withAlphaComponent(1)
    }

    var markdownSRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue, alpha)
    }

    var markdownCSSColor: String {
        let (red, green, blue, alpha) = markdownSRGBComponents
        let r = min(255, max(0, Int((red * 255).rounded())))
        let g = min(255, max(0, Int((green * 255).rounded())))
        let b = min(255, max(0, Int((blue * 255).rounded())))
        let a = min(1, max(0, alpha))
        return String(format: "rgba(%d, %d, %d, %.3f)", r, g, b, Double(a))
    }

    func markdownWithAlphaScaled(_ factor: CGFloat) -> UIColor {
        let (_, _, _, alpha) = markdownSRGBComponents
        return withAlphaComponent(alpha * factor)
    }

    func markdownBlended(withFraction fraction: CGFloat, of other: UIColor) -> UIColor {
        let a = markdownSRGBComponents
        let b = other.markdownSRGBComponents
        let f = min(1, max(0, fraction))
        return UIColor(
            red: a.red + (b.red - a.red) * f,
            green: a.green + (b.green - a.green) * f,
            blue: a.blue + (b.blue - a.blue) * f,
            alpha: a.alpha + (b.alpha - a.alpha) * f
        )
    }

    /// Finds the smallest overlay fraction of `color` whose blend against the
    /// base reaches the target WCAG contrast ratio — same math as the macOS
    /// theme so both platforms land on matching CSS variables.
    func markdownThemeOverlay(targetContrast: CGFloat, of color: UIColor) -> UIColor {
        let base = markdownOpaqueSRGB
        let overlay = color.markdownOpaqueSRGB
        var low: CGFloat = 0
        var high: CGFloat = 1
        var result: CGFloat = 1

        for _ in 0..<18 {
            let mid = (low + high) / 2
            let candidate = base.markdownBlended(withFraction: mid, of: overlay)
            if candidate.markdownContrastRatio(with: base) < Double(targetContrast) {
                low = mid
            } else {
                high = mid
                result = mid
            }
        }

        return overlay.withAlphaComponent(result)
    }

    var markdownRelativeLuminance: Double {
        let (red, green, blue, _) = markdownSRGBComponents

        func linear(_ component: CGFloat) -> Double {
            let value = Double(component)
            if value <= 0.04045 {
                return value / 12.92
            }
            return pow((value + 0.055) / 1.055, 2.4)
        }

        return (0.2126 * linear(red)) + (0.7152 * linear(green)) + (0.0722 * linear(blue))
    }

    func markdownContrastRatio(with other: UIColor) -> Double {
        let first = markdownRelativeLuminance
        let second = other.markdownRelativeLuminance
        let lighter = max(first, second)
        let darker = min(first, second)
        return (lighter + 0.05) / (darker + 0.05)
    }
}
#endif
