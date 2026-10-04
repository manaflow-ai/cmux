import AppKit
@testable import CmuxNextDesign
import Testing

/// Lawrence R48: every surface shows the one window background at every
/// opacity. A page or tab view that must give a background somewhere
/// (Home's scene, the Feed, History, Tasks and Bookmarks pages) takes
/// `Palette.paneFill`: the surface token, opaque, in an opaque window and
/// clear over a see-through one, where the window's one backdrop is the
/// background. A tint of its own over the backdrop would show the
/// background twice (scripts/cmux-next/background-match-e2e.py).
@MainActor @Suite(.serialized) struct PaneFillTests {
    private func fill(opacity: Double, blur: Int) -> (NSColor, ThemeTokens) {
        let scope = ThemeScope(level: .room)
        var input = ThemeScope.app.input
        input.backgroundOpacity = opacity
        input.backgroundBlur = blur
        scope.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        return (scope.perform { Palette.paneFill }, scope.tokens)
    }

    @Test(arguments: [(0.8, 0), (0.8, 20), (0.5, 0), (0.5, 20)])
    func aSeeThroughWindowsPanesFillNothing(_ opacity: Double, _ blur: Int) {
        let (color, _) = fill(opacity: opacity, blur: blur)
        #expect(color.alphaComponent == 0, "opacity \(opacity) blur \(blur)")
    }

    @Test func anOpaqueWindowsPanesFillTheSurfaceToken() throws {
        let (color, tokens) = fill(opacity: 1, blur: 0)
        let rgb = try #require(color.usingColorSpace(.sRGB))
        let token = tokens.surfaceBackground
        #expect(rgb.alphaComponent == 1)
        #expect(abs(rgb.redComponent - token.red) < 0.002 && abs(rgb.greenComponent - token.green) < 0.002
            && abs(rgb.blueComponent - token.blue) < 0.002)
    }
}
