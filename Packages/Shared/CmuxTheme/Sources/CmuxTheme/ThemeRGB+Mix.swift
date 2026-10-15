import Foundation

/// Where two colors blend in a color transition (`appearance.colorTransition.colorSpace`).
public enum ThemeColorSpace: String, Sendable, Hashable, CaseIterable {
    /// Perceptual: lightness moves evenly, so two hues never pass through a muddy or dark middle.
    case oklab
    /// The plain channel mix (what browsers do for legacy `rgb()` colors).
    case srgb
}

extension ThemeRGB {
    /// The color `fraction` of the way from this color to `other` (0 is this color, 1 is `other`;
    /// values outside 0...1 are clamped, so a spring's overshoot holds at the target). Opacity
    /// mixes linearly and the color components mix premultiplied by it, as CSS Color 4 does, so a
    /// fade from a clear color does not take on the clear color's hue.
    public func mixed(with other: ThemeRGB, fraction: Double, in space: ThemeColorSpace) -> ThemeRGB {
        let t = min(max(fraction.isNaN ? 1 : fraction, 0), 1)
        if t == 0 { return self }
        if t == 1 { return other }
        let mixedAlpha = self.alpha + (other.alpha - self.alpha) * t
        let from = space.components(of: self), to = space.components(of: other)
        func mix(_ a: Double, _ b: Double) -> Double {
            let value = a * self.alpha + (b * other.alpha - a * self.alpha) * t
            return mixedAlpha > 0 ? value / mixedAlpha : 0
        }
        // With both colors opaque this is a plain mix.
        let mixed = (mix(from.0, to.0), mix(from.1, to.1), mix(from.2, to.2))
        var color = space.color(from: mixed)
        color.alpha = mixedAlpha
        return color
    }
}

extension ThemeColorSpace {
    /// The color's three components in this space.
    func components(of color: ThemeRGB) -> (Double, Double, Double) {
        switch self {
        case .srgb: return (color.red, color.green, color.blue)
        case .oklab:
            let r = AppColor.linear(color.red), g = AppColor.linear(color.green), b = AppColor.linear(color.blue)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                    1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                    0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)
        }
    }

    /// The sRGB color of three components in this space (clamped into gamut per channel; a mix
    /// of two in-gamut colors in OKLab stays very near the gamut).
    func color(from components: (Double, Double, Double)) -> ThemeRGB {
        switch self {
        case .srgb: return ThemeRGB(red: components.0, green: components.1, blue: components.2)
        case .oklab:
            let (lightness, a, b) = components
            let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(lightness - 0.0894841775 * a - 1.291485548 * b, 3)
            func channel(_ c: Double) -> Double { AppColor.gamma(min(max(c, 0), 1)) }
            return ThemeRGB(red: channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                            green: channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                            blue: channel(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s))
        }
    }
}
