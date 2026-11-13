public import CmuxTheme
import Foundation

/// The color a new space or browser profile takes: the palette color that looks the most unlike the ones there are.
extension GroupColor {
    /// The color a new space or browser profile gets after `existing`: every palette color once before any repeats,
    /// each the one farthest by eye (OKLab, ``perceptualDistance(to:)``) from the colors this round already holds; at
    /// the start of a round, the farthest from the last profile's. Ties go to the earlier in ``paletteOrder``.
    /// A recolored profile counts with its new color; no color, or a token this build doesn't know, counts for none.
    /// Deterministic: the same colors always give the same answer.
    /// - Parameter existing: The profiles' color tokens, oldest first.
    /// - Returns: The new profile's color; never blue or grey.
    nonisolated public static func automatic(after existing: [String]) -> GroupColor {
        let tokens = existing.compactMap(GroupColor.init(rawValue:))
        var counts: [GroupColor: Int] = [:]
        for token in tokens { counts[token, default: 0] += 1 }
        // No grey and no blue (an app-picked blue reads as the unread dot); a tie goes to the earlier one.
        let candidates = paletteOrder
        let round = candidates.map { counts[$0] ?? 0 }.min() ?? 0
        let open = candidates.filter { (counts[$0] ?? 0) == round }
        let taken = candidates.filter { (counts[$0] ?? 0) > round }
        // A blue or grey profile (a person's pick) still pushes the next color away from it.
        let near = taken + tokens.filter { !candidates.contains($0) }
        let reference = near.isEmpty ? (tokens.last.map { [$0] } ?? []) : near
        guard !reference.isEmpty else { return open.first ?? .purple }
        var best = open[0], bestDistance = -1.0
        for color in open {
            let distance = reference.map { color.perceptualDistance(to: $0) }.min() ?? 0
            if distance > bestDistance + 1e-9 { best = color; bestDistance = distance }
        }
        return best
    }

    /// How far apart two tokens look: the OKLab distance between their vibrant swatches, the smaller of the light and
    /// dark variants, so two colors far apart here read as different in both appearances.
    /// - Parameter other: The token to compare with.
    /// - Returns: The distance; 0 for the same token, about 0.3 for colors across the wheel.
    nonisolated public func perceptualDistance(to other: GroupColor) -> Double {
        min(Self.oklab(rgb(.swatch, dark: true)).distance(to: Self.oklab(other.rgb(.swatch, dark: true))),
            Self.oklab(rgb(.swatch, dark: false)).distance(to: Self.oklab(other.rgb(.swatch, dark: false))))
    }

    private nonisolated static func oklab(_ color: ThemeRGB) -> OKLabPoint {
        let lch = color.oklch
        let radians = lch.hue * .pi / 180
        return OKLabPoint(lightness: lch.lightness, a: lch.chroma * cos(radians), b: lch.chroma * sin(radians))
    }
}

/// A color as an OKLab point, where straight-line distance tracks how different two colors look.
private nonisolated struct OKLabPoint {
    let lightness: Double
    let a: Double
    let b: Double

    func distance(to other: OKLabPoint) -> Double {
        let dl = lightness - other.lightness, da = a - other.a, db = b - other.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}
