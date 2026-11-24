import AppKit
import CmuxNextDesign
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// The palette's search placeholder names what the field takes, so it reads at 4.5:1: the theme's
/// secondary ink, as every native field's placeholder (`ThemedTextField`) and every web field's
/// (ui/controls.css). The tertiary ink held 3.61:1 (light) and 4.00:1 (dark) on a field fill (the
/// browser's Find bar; fleet capture of a60fd539, text-inputs-glass/states.py).
@MainActor
@Suite(.closesItsWindows)
struct PaletteSearchPlaceholderInkTests {
    @Test func theSearchPlaceholderIsTheSecondaryInk() throws {
        let bar = PaletteSearchBar(frame: NSRect(x: 0, y: 0, width: 600, height: PaletteLayout.searchHeight))
        bar.update(query: "", placeholder: PaletteStrings.searchEverythingPlaceholder, chips: [], rootTitle: "", style: .token,
                   keywordHint: nil, isLoading: false)
        let placeholder = try #require(bar.field.placeholderAttributedString)
        let ink = try #require(placeholder.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let expected = bar.performWithTheme { Palette.textSecondary }
        #expect(ink.usingColorSpace(.sRGB) == expected.usingColorSpace(.sRGB), "placeholder \(ink) vs secondary \(expected)")
    }
}
