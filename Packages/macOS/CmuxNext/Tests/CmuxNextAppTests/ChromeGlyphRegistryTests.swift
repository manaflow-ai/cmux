import AppKit
import CmuxNextDesign
import CmuxNextIcons
import Testing
@testable import CmuxNextApp

/// Small chrome glyphs (the incognito badge, remote and elsewhere
/// placeholders) come from the cmux icon registry at the size of the text
/// beside them, not stock SF Symbols at a fixed point size.
@MainActor @Suite struct ChromeGlyphRegistryTests {
    private func square(_ side: CGFloat) -> NSSize { NSSize(width: side, height: side) }

    @Test func theIncognitoBadgeGlyphMatchesItsCaption() throws {
        let image = try #require(IncognitoBadgeView(frame: .zero).glyph)
        #expect(image.isTemplate)
        #expect(image.size == square(.iconRowSize(forLabelPointSize: Typography.caption.pointSize)))
    }

    @Test func placeholderGlyphsMatchTheirStatusText() throws {
        let side = CGFloat.iconRowSize(forLabelPointSize: NSFont.systemFontSize)
        let remote = try #require(RemoteTerminalPlaceholderView(frame: .zero).glyph)
        let elsewhere = try #require(AgentTabElsewhereView(machine: "mini").glyph)
        #expect(remote.isTemplate && elsewhere.isTemplate)
        #expect(remote.size == square(side))
        #expect(elsewhere.size == square(side))
    }
}
