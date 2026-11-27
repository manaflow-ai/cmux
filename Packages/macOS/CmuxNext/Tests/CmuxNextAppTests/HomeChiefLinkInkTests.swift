import AppKit
@testable import CmuxNextDesign
@testable import CmuxNextHomeEngine
import CmuxNextTestSupport
import CmuxTheme
import Testing

/// Leo's screenshot of the Chief Settings card (2026-10-20): Show Traces and Show Memory were dim grey,
/// fainter than the card's secondary text. The links drew the raw accent, which in a theme that names
/// no accent is its focus ring, 40% of the text. A link draws the lit accent (`Palette.litGlyph`),
/// which reads at least as well as secondary text and keeps a theme's own accent hue.
@MainActor @Suite(.serialized, .closesItsWindows) struct HomeChiefLinkInkTests {
    @Test func aLinkReadsAtLeastAsWellAsSecondaryText() throws {
        let input = ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6), palette: [])
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 80), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        window.contentView = root
        let scope = ThemeScope(level: .room)
        scope.setOverride(try #require(ThemeSpec("Plain Dark")), input: input, animated: false)
        scope.root(root)
        let link = HomeChiefLinkButton(title: HomeEngineStrings.showMemory, target: root, action: #selector(NSView.display as (NSView) -> () -> Void))
        root.addSubview(link)
        let drawn = try #require(link.attributedTitle.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let (lit, raw) = scope.perform { (Palette.litGlyph, Palette.accent) }
        // This theme names no accent, so its raw accent is the dim focus ring the links drew before.
        #expect(lit != raw, "the theme's raw accent already reads; the test needs one that does not")
        #expect(drawn == lit, "the link draws \(drawn), not the lit accent \(lit)")
        let tokens = ThemeTokens.derive(from: input)
        let surface = tokens.windowBackground.withAlpha(1)
        #expect(tokens.litGlyph.contrast(with: surface) >= tokens.textSecondary.composited(over: surface).contrast(with: surface))
    }
}
