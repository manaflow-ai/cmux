public import Foundation

/// The broad tonal value used when selecting readable chrome treatments.
public enum BackdropArtTone: String, CaseIterable, Equatable, Sendable {
    case light
    case dark
}

/// One sampled color from a backdrop's dominant palette.
public struct BackdropPaletteColor: Equatable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public nonisolated init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public nonisolated var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

/// Layout hints authored with each bundled artwork.
public struct BackdropArtMetadata: Equatable, Sendable {
    public let focalAnchor: BackdropFocalAnchor
    /// The subject to keep whole and clear of the panes over the art; nil for art that names
    /// only its focal anchor (``placement(forViewSize:imageSize:visible:)``).
    public let subjectBox: BackdropSubjectBox?
    /// The part of the image that is the painting, from the top-left: a side render sets a tall
    /// work beside a blurred, darkened fill of itself, and the window covers itself with the
    /// painting alone, never that fill. Nil when the whole image is the painting.
    public let panel: BackdropSubjectBox?
    public let tone: BackdropArtTone
    public let dominantPalette: [BackdropPaletteColor]
    public let quietZone: BackdropQuietZone
    /// The least theme tint drawn over the art at full window opacity, above the theme's own
    /// `ThemeTokens.wallpaperTintOpacity`. 0 leaves the theme's tint.
    public let minimumTintOpacity: Double
    /// The tint this work looks best under, replacing the theme's own when set: dark works show
    /// more of themselves. The legibility floor still applies on top.
    public let preferredTintOpacity: Double?
    /// The measured darkest and lightest colors of the work, so the legibility floor need not
    /// assume the art could be anything from black to white.
    public let range: BackdropArtRange?

    public nonisolated init(focalAnchor: BackdropFocalAnchor, tone: BackdropArtTone,
                dominantPalette: [BackdropPaletteColor], quietZone: BackdropQuietZone,
                minimumTintOpacity: Double = 0, preferredTintOpacity: Double? = nil,
                range: BackdropArtRange? = nil, subjectBox: BackdropSubjectBox? = nil,
                panel: BackdropSubjectBox? = nil) {
        self.focalAnchor = focalAnchor
        self.subjectBox = subjectBox
        self.panel = panel
        self.tone = tone
        self.dominantPalette = dominantPalette
        self.quietZone = quietZone
        self.minimumTintOpacity = minimumTintOpacity
        self.preferredTintOpacity = preferredTintOpacity
        self.range = range
    }
}

