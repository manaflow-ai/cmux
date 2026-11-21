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
}
