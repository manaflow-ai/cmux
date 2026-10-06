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

    /// Narrowed by the titlebar row, the badge shows its glyph alone instead
    /// of a clipped word, and the word returns when room does.
    @Test func aNarrowIncognitoBadgeDropsItsWord() {
        let badge = IncognitoBadgeView(frame: .zero)
        let full = badge.fittingSize
        badge.frame = NSRect(origin: .zero, size: full)
        badge.layoutSubtreeIfNeeded()
        #expect(badge.showsLabel)
        badge.frame = NSRect(x: 0, y: 0, width: full.height + 6, height: full.height)
        badge.layoutSubtreeIfNeeded()
        #expect(!badge.showsLabel)
        #expect(badge.fittingSize.width == full.width)
        badge.frame = NSRect(origin: .zero, size: full)
        badge.layoutSubtreeIfNeeded()
        #expect(badge.showsLabel)
    }
}
