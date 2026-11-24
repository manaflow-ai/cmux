public import CmuxTheme
public import CmuxNextDesignTokens

/// A group gradient's colors (`sidebar.groupGradient`, ``GroupGradient``): what the ``GroupPalette/gradient`` palette
/// draws a group in, from its place among the colored groups.
extension GroupGradient {
    /// The color at `place` (0 the first stop, 1 the last): OKLCH lightness and chroma straight between the two stops
    /// around it and the hue the short way round, so a blend keeps its chroma and never passes through grey or brown.
    /// Out of sRGB the chroma drops until it fits; the hue and lightness hold.
    nonisolated public func rgb(at place: Double) -> ThemeRGB {
        let stops = self.stops
        guard let first = stops.first else { return .white }
        guard stops.count > 1 else { return ThemeRGB(oklchLightness: first.lightness, chroma: first.chroma, hue: first.hue) }
        let scaled = min(max(place, 0), 1) * Double(stops.count - 1)
        let index = min(Int(scaled), stops.count - 2)
        let t = scaled - Double(index)
        let a = stops[index], b = stops[index + 1]
        let turn = (b.hue - a.hue + 540).truncatingRemainder(dividingBy: 360) - 180
        return ThemeRGB(oklchLightness: a.lightness + (b.lightness - a.lightness) * t,
                        chroma: a.chroma + (b.chroma - a.chroma) * t,
                        hue: (a.hue + turn * t + 360).truncatingRemainder(dividingBy: 360))
    }

    /// Where the `index`th of `count` colored groups sits on the gradient: spread from the first stop to the last, so
    /// the list always runs the whole gradient; a lone group takes the first stop.
    nonisolated public static func place(_ index: Int, of count: Int) -> Double {
        count > 1 ? Double(index) / Double(count - 1) : 0
    }
}
