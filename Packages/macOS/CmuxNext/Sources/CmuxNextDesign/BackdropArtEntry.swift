public import Foundation
public import CmuxNextDesignTokens

/// One work's catalog record, generated from `art/manifest.json` with
/// `scripts/cmux-next/art/generate_backdrop_art.py` (cx-t2x.7).
public nonisolated struct BackdropArtEntry: Sendable {
    public let artist: String
    public let year: String
    /// The holding museum or the book the plate comes from.
    public let museum: String
    public let collection: BackdropArtCollection
    /// The Wikimedia Commons file page the image came from.
    public let source: String
    /// The Commons license, e.g. "Public domain [PD-Art, PD-old-100]".
    public let license: String
    /// The SHA-256 of the full 1600×1000 AVIF, its name on files.cmux.com.
    public let sha256: String
    /// Whether the full image ships in the app (the dark starter set).
    public let bundled: Bool
    /// The subject, as a fraction of the image from its top-left corner.
    let focal: (x: Double, y: Double)
    /// What to keep whole and clear of the panes over the art, as fractions of the image from its
    /// top-left corner (`subject` in the manifest).
    let subject: (minX: Double, minY: Double, maxX: Double, maxY: Double)
    let tone: BackdropArtTone
    /// The dominant colors, most common first, as 0xRRGGBB.
    let palette: [UInt32]
    /// Whether the dark, quiet side for text is the left one.
    let quietLeft: Bool
    /// Catalog data the window no longer reads: the tint once suggested for the work, and the
    /// darkest and lightest pixels of the full image as 0xRRGGBB. Every picture now gets the same
    /// tint (`WindowBackdrop`).
    let tint: Double
    let darkest: UInt32
    let lightest: UInt32

    /// The layout and tonal hints the backdrop renderer reads.
    var metadata: BackdropArtMetadata {
        BackdropArtMetadata(
            focalAnchor: .init(x: focal.x, y: focal.y),
            tone: tone,
            dominantPalette: palette.map {
                BackdropPaletteColor(red: UInt8($0 >> 16 & 0xFF), green: UInt8($0 >> 8 & 0xFF), blue: UInt8($0 & 0xFF))
            },
            quietZone: quietLeft
                ? .init(x: 0.02, y: 0.06, width: 0.42, height: 0.88)
                : .init(x: 0.56, y: 0.06, width: 0.42, height: 0.88),
            subjectBox: BackdropSubjectBox(minX: subject.minX, minY: subject.minY, maxX: subject.maxX, maxY: subject.maxY)
        )
    }
}
