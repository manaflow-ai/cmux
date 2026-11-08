import CoreText
import Foundation

/// A small, CI-runnable check for the metrics Ghostty uses for terminal cells.
/// It intentionally measures the chosen face and CoreText's fallback face rather than an
/// AppKit label: a fallback that draws a glyph but advances by a different number of cells is
/// still a terminal rendering bug.
public nonisolated struct GhosttyGlyphWidthProbe: Sendable {
    public struct Sample: Sendable, Equatable {
        public let name: String
        public let text: String
        public let expectedCells: Int

        public init(name: String, text: String, expectedCells: Int) {
            self.name = name
            self.text = text
            self.expectedCells = expectedCells
        }
    }

    public struct Measurement: Sendable, Equatable {
        public let sample: Sample
        public let cellWidth: Double
        public let advance: Double
        public let missingGlyph: Bool

        public var expectedAdvance: Double { cellWidth * Double(sample.expectedCells) }
        public var cellDelta: Double { advance - expectedAdvance }
        public var overflowsCellGrid: Bool {
            abs(cellDelta) > max(0.5, cellWidth * 0.25)
        }
        public var matchesCellGrid: Bool { !missingGlyph && !overflowsCellGrid }
    }

    /// The fixed prompt/content probe: ASCII, CJK, Nerd Font private-use code points, and emoji.
    public static let samples = [
        Sample(name: "ASCII", text: "Aa", expectedCells: 2),
        Sample(name: "CJK", text: "日本語", expectedCells: 6),
        Sample(name: "Nerd Font", text: "\u{f007}\u{f120}", expectedCells: 2),
        Sample(name: "Emoji", text: "😀", expectedCells: 2),
    ]

    public let family: String
    public let size: Double
    public let measurements: [Measurement]

    public init(family: String, size: Double, fallbackFamilies: [String] = GhosttyRuntime.knownFallbackFamilies) {
        self.family = family
        self.size = size
        let pointSize = CGFloat(size.isFinite && size > 0 ? size : 13)
        let primary = CTFontCreateWithName(family as CFString, pointSize, nil)
        let fallbackFonts = ([family] + fallbackFamilies).reduce(into: [CTFont]()) { fonts, name in
            guard !name.isEmpty else { return }
            let font = CTFontCreateWithName(name as CFString, pointSize, nil)
            if !fonts.contains(where: { CTFontCopyPostScriptName($0) == CTFontCopyPostScriptName(font) }) {
                fonts.append(font)
            }
        }
        let cellWidth = Self.shapedAdvance(for: "M", in: primary)
        measurements = Self.samples.map {
            Self.measure($0, primary: primary, fallbackFonts: fallbackFonts, cellWidth: cellWidth)
        }
    }

    public var allSamplesMatchCellGrid: Bool { measurements.allSatisfy(\.matchesCellGrid) }

    private static func measure(_ sample: Sample, primary: CTFont, fallbackFonts: [CTFont], cellWidth: Double) -> Measurement {
        let string = sample.text as NSString
        let (font, missing) = fontAndFontCoverage(for: string, primary: primary, fallbackFonts: fallbackFonts)
        return Measurement(sample: sample, cellWidth: cellWidth, advance: shapedAdvance(for: sample.text, in: font), missingGlyph: missing)
    }

    private static func fontAndFontCoverage(for string: NSString, primary: CTFont, fallbackFonts: [CTFont]) -> (CTFont, Bool) {
        for font in fallbackFonts {
            if !hasMissingGlyph(for: string, in: font) { return (font, false) }
        }
        let fallback = CTFontCreateForString(primary, String(string) as CFString, CFRange(location: 0, length: string.length))
        return (fallback, hasMissingGlyph(for: string, in: fallback))
    }

    /// Map one Unicode scalar at a time so an emoji surrogate pair is one glyph, not a glyph plus
    /// a false missing continuation slot.
    private static func hasMissingGlyph(for string: NSString, in font: CTFont) -> Bool {
        for scalar in String(string).unicodeScalars {
            let unitString = String(scalar) as NSString
            var characters = [UniChar](repeating: 0, count: unitString.length)
            unitString.getCharacters(&characters, range: NSRange(location: 0, length: unitString.length))
            var glyphs = [CGGlyph](repeating: 0, count: unitString.length)
            let mapped = characters.withUnsafeBufferPointer { characters in
                glyphs.withUnsafeMutableBufferPointer { glyphs in
                    guard let charactersBase = characters.baseAddress, let glyphsBase = glyphs.baseAddress else { return false }
                    return CTFontGetGlyphsForCharacters(font, charactersBase, glyphsBase, unitString.length)
                }
            }
            if !mapped || glyphs[0] == 0 { return true }
        }
        return false
    }

    /// Shape the complete string: this handles surrogate pairs and any kerning/cluster advance
    /// CoreText applies, so the probe compares the actual rendered run to the terminal cell grid.
    private static func shapedAdvance(for string: String, in font: CTFont) -> Double {
        let attributed = NSAttributedString(string: string, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        return CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
