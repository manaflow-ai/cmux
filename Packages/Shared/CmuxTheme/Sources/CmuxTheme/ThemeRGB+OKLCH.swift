import Foundation

extension ThemeRGB {
    /// An OKLCH color in sRGB (`AppColor`'s conversion): out of gamut, its chroma drops until it fits, so its hue and
    /// lightness hold and it never turns to a duller neighbor hue.
    /// - Parameters:
    ///   - lightness: OKLCH lightness, 0...1.
    ///   - chroma: OKLCH chroma.
    ///   - hue: Hue in degrees.
    public init(oklchLightness lightness: Double, chroma: Double, hue: Double) {
        self = AppColor.fromOKLCH(AppColor.OKLCH(l: lightness, c: chroma, h: hue))
    }

    /// The color's OKLCH lightness, chroma and hue (degrees, 0..<360).
    public var oklch: (lightness: Double, chroma: Double, hue: Double) {
        let value = AppColor.oklch(self)
        return (value.l, value.c, value.h)
    }

    /// The color, as its 8-bit hex rounds it, with the smallest OKLCH lightness change that gives it at least each
    /// minimum contrast (the app theme's own fit; Rust `cmux_theme_tokens::fit_contrast`).
    /// - Parameters:
    ///   - constraints: Each color it sits on or under, with the WCAG 2 contrast it needs there.
    ///   - lighter: Which way to try first; nil: away from the constraints' average.
    /// - Returns: The fitted opaque color.
    public func fitted(contrast constraints: [(on: ThemeRGB, minimum: Double)], lighter: Bool?) -> ThemeRGB {
        AppColor.fit(self, constraints.map { AppColor.Constraint(on: $0.on, minimum: $0.minimum) },
                     prefer: lighter.map { $0 ? .lighter : .darker })
    }
}
