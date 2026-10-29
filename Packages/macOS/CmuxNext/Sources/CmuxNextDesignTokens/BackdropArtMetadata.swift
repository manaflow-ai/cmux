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
    /// Where the work's subject is (catalog data); nil for art that names only its focal anchor.
    public let subjectBox: BackdropSubjectBox?
    public let tone: BackdropArtTone
    public let dominantPalette: [BackdropPaletteColor]
    public let quietZone: BackdropQuietZone

    public nonisolated init(focalAnchor: BackdropFocalAnchor, tone: BackdropArtTone,
                dominantPalette: [BackdropPaletteColor], quietZone: BackdropQuietZone,
                subjectBox: BackdropSubjectBox? = nil) {
        self.focalAnchor = focalAnchor
        self.subjectBox = subjectBox
        self.tone = tone
        self.dominantPalette = dominantPalette
        self.quietZone = quietZone
    }
}

