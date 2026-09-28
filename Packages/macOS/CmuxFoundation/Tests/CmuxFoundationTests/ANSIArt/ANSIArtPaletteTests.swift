import SwiftUI
import Testing

@testable import CmuxFoundation

/// Behavior tests for ``ANSIArtPalette`` color resolution and the
/// ``ANSIArt/attributedString(palette:)`` projection the empty pane renders.
@Suite struct ANSIArtPaletteTests {
    private let foreground = ANSIArtRGB(200, 200, 200)
    private let background = ANSIArtRGB(10, 10, 10)

    private var palette: ANSIArtPalette {
        ANSIArtPalette(foreground: foreground, background: background)
    }

    @Test func baseColorsFallBackToXtermAndHonorOverrides() {
        #expect(palette.rgb(forIndex: 1) == ANSIArtRGB(205, 0, 0))
        #expect(palette.rgb(forIndex: 12) == ANSIArtRGB(92, 92, 255))
        let themed = ANSIArtPalette(
            foreground: foreground,
            background: background,
            overrides: [1: ANSIArtRGB(1, 2, 3), 200: ANSIArtRGB(4, 5, 6)]
        )
        #expect(themed.rgb(forIndex: 1) == ANSIArtRGB(1, 2, 3))
        #expect(themed.rgb(forIndex: 200) == ANSIArtRGB(4, 5, 6))
    }

    @Test func extendedIndexesUseTheXtermCubeAndGrayRamp() {
        #expect(palette.rgb(forIndex: 16) == ANSIArtRGB(0, 0, 0))
        #expect(palette.rgb(forIndex: 208) == ANSIArtRGB(255, 135, 0))
        #expect(palette.rgb(forIndex: 231) == ANSIArtRGB(255, 255, 255))
        #expect(palette.rgb(forIndex: 232) == ANSIArtRGB(8, 8, 8))
        #expect(palette.rgb(forIndex: 255) == ANSIArtRGB(238, 238, 238))
        // Out-of-range indexes never trap; they read as the default foreground.
        #expect(palette.rgb(forIndex: 256) == foreground)
        #expect(palette.rgb(forIndex: -1) == foreground)
    }

    @Test func inverseSwapsResolvedColorsIncludingDefaults() {
        var style = ANSIArtStyle()
        #expect(palette.resolvedColors(for: style).foreground == foreground)
        #expect(palette.resolvedColors(for: style).background == nil)

        style.isInverse = true
        #expect(palette.resolvedColors(for: style).foreground == background)
        #expect(palette.resolvedColors(for: style).background == foreground)

        style.foreground = .rgb(ANSIArtRGB(1, 1, 1))
        style.background = .indexed(2)
        #expect(palette.resolvedColors(for: style).foreground == ANSIArtRGB(0, 205, 0))
        #expect(palette.resolvedColors(for: style).background == ANSIArtRGB(1, 1, 1))
    }

    @Test func attributedStringJoinsLinesAndCarriesColors() throws {
        let art = try #require(ANSIArtParser().parse("\u{1B}[1;31mab\u{1B}[0m\n\u{1B}[44mc"))
        let text = art.attributedString(palette: palette)
        #expect(String(text.characters) == "ab\nc")

        let runs = Array(text.runs)
        let bold = try #require(runs.first)
        #expect(bold[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] != nil)
        #expect(bold[AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self] == .stronglyEmphasized)
        let last = try #require(runs.last)
        #expect(last[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] != nil)
        #expect(bold[AttributeScopes.SwiftUIAttributes.BackgroundColorAttribute.self] == nil)
    }
}
