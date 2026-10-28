public import CmuxTheme
import Foundation
public import CmuxNextDesignTokens

extension BackdropArt {
    /// The hue Art Color (`appearance.accent: "art"`) takes from this work: the most colorful of its
    /// dominant colors that reads as a hue (not near black or gray), nil when none does (the accent
    /// stays the theme's). `AppTheme` then moves it until every contrast pair of its contract passes.
    public var accentHue: ThemeRGB? {
        let hued = metadata.dominantPalette.compactMap { color -> (BackdropPaletteColor, Double)? in
            let channels = [color.red, color.green, color.blue].map { Double($0) / 255 }
            let high = channels.max() ?? 0, chroma = high - (channels.min() ?? 0)
            guard high >= Self.minimumAccentValue, chroma >= high * Self.minimumAccentSaturation else { return nil }
            return (color, chroma)
        }
        guard let best = hued.max(by: { $0.1 < $1.1 }) else { return nil }
        return ThemeRGB(r: best.0.red, g: best.0.green, b: best.0.blue)
    }

    /// Darker than this (HSV value) a color reads as black, whatever its hue.
    static let minimumAccentValue = 0.15
    /// Below this HSV saturation a color reads as gray.
    static let minimumAccentSaturation = 0.3
}
