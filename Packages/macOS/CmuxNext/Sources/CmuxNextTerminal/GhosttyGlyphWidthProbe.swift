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
        let cellWidth = Self.advance(for: "M", in: primary)
        measurements = Self.samples.map {
            Self.measure($0, primary: primary, fallbackFonts: fallbackFonts, cellWidth: cellWidth)
        }
    }

    public var allSamplesMatchCellGrid: Bool { measurements.allSatisfy(\.matchesCellGrid) }

    private static func measure(_ sample: Sample, primary: CTFont, fallbackFonts: [CTFont], cellWidth: Double) -> Measurement {
        let string = sample.text as NSString
        let (font, glyphs, missing) = fontAndGlyphs(for: string, primary: primary, fallbackFonts: fallbackFonts)
        return Measurement(sample: sample, cellWidth: cellWidth, advance: advance(for: glyphs, in: font), missingGlyph: missing)
    }

    private static func fontAndGlyphs(for string: NSString, primary: CTFont, fallbackFonts: [CTFont]) -> (CTFont, [CGGlyph], Bool) {
        for font in fallbackFonts {
            let glyphs = glyphs(for: string, in: font)
            if !glyphs.contains(0) { return (font, glyphs, false) }
        }
        let fallback = CTFontCreateForString(primary, string as CFString, CFRange(location: 0, length: string.length))
        let glyphs = glyphs(for: string, in: fallback)
        return (fallback, glyphs, glyphs.contains(0))
    }

    private static func glyphs(for string: NSString, in font: CTFont) -> [CGGlyph] {
        guard string.length > 0 else { return [] }
        var characters = [UniChar](repeating: 0, count: string.length)
        string.getCharacters(&characters, range: NSRange(location: 0, length: string.length))
        var glyphs = [CGGlyph](repeating: 0, count: string.length)
        let mapped = characters.withUnsafeMutableBufferPointer { characters in
            glyphs.withUnsafeMutableBufferPointer { glyphs in
                CTFontGetGlyphsForCharacters(font, characters.baseAddress!, glyphs.baseAddress!, string.length)
            }
        }
        return mapped ? glyphs : glyphs.map { _ in 0 }
    }

    private static func advance(for text: String, in font: CTFont) -> Double {
        advance(for: glyphs(for: text as NSString, in: font), in: font)
    }

    private static func advance(for glyphs: [CGGlyph], in font: CTFont) -> Double {
        guard !glyphs.isEmpty else { return 0 }
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        let total = glyphs.withUnsafeBufferPointer { glyphs in
            advances.withUnsafeMutableBufferPointer { advances in
                CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs.baseAddress!, advances.baseAddress!, glyphs.count)
            }
        }
        return total
    }
}
