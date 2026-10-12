public import CmuxTheme
import Foundation

extension BackdropArt {
    /// The hue Art Color (`appearance.accent: "art"`) takes from this work: its most colorful
    /// dominant color, nil when every one is near gray (the accent stays the theme's). `AppTheme`
    /// then moves it until every contrast pair of its contract passes.
    public var accentColor: ThemeRGB? {
        let scored = metadata.dominantPalette.map { color in
            let channels = [color.red, color.green, color.blue].map { Double($0) / 255 }
            return (color, (channels.max() ?? 0) - (channels.min() ?? 0))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= Self.minimumAccentChroma else { return nil }
        return ThemeRGB(r: best.0.red, g: best.0.green, b: best.0.blue)
    }

    /// Below this chroma (max - min channel) a color reads as gray, not a hue.
    static let minimumAccentChroma = 0.2
}
