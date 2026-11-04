import AppKit
import Testing
@testable import CmuxNextDesign

/// The path that stays when the shared glyph cache (`sharedGlyphMasks`, prove-or-remove 11-04) goes: each
/// ``ChromeLabel`` keeps its own glyph image, draws it once for its text and draws again only when the
/// text changes.
@MainActor @Suite struct ChromeLabelOwnGlyphsTests {
    @Test func aLabelKeepsItsOwnGlyphImageUntilItsTextChanges() throws {
        let label = ChromeLabel(labelWithString: "Label")
        label.wantsLayer = true
        label.setFrameSize(NSSize(width: 80, height: 16))
        label.updateLayer()
        let glyphs = try #require(label.layer?.sublayers?.first?.mask)
        let first = try #require(glyphs.contents as AnyObject?)
        label.updateLayer()
        #expect((glyphs.contents as AnyObject?) === first, "an unchanged label drew its glyphs again")
        label.stringValue = "Other"
        label.updateLayer()
        #expect((glyphs.contents as AnyObject?) !== first, "a new text kept the old glyphs")
    }
}
