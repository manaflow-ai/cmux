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
                range: BackdropArtRange? = nil) {
        self.focalAnchor = focalAnchor
        self.tone = tone
        self.dominantPalette = dominantPalette
        self.quietZone = quietZone
        self.minimumTintOpacity = minimumTintOpacity
        self.preferredTintOpacity = preferredTintOpacity
        self.range = range
    }

    /// Returns the normalized aspect-fill crop, keeping the focal anchor visible.
    /// The anchor's y coordinate is measured from the top, while Core Animation's
    /// `contentsRect` uses a bottom-left origin.
    public nonisolated func cropRect(forViewSize viewSize: CGSize, imageSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let viewAspect = viewSize.width / viewSize.height
        let imageAspect = imageSize.width / imageSize.height
        let visibleWidth = min(1, viewAspect / imageAspect)
        let visibleHeight = min(1, imageAspect / viewAspect)
        let x = min(max(focalAnchor.x - visibleWidth / 2, 0), 1 - visibleWidth)
        let topOrigin = min(max(focalAnchor.y - visibleHeight / 2, 0), 1 - visibleHeight)
        return CGRect(x: x, y: 1 - topOrigin - visibleHeight,
                      width: visibleWidth, height: visibleHeight)
    }
}

