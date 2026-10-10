import AppKit
import CmuxHomeRender
import CmuxNextDesign
@testable import CmuxNextHome
import Testing

/// Lawrence R48: Home's scene paints the pane's fill (`Palette.paneFill`),
/// never an opaque color or an inactive tint of its own, so Home matches
/// every other surface at every window opacity.
@MainActor @Suite(.serialized) struct HomeBackgroundTests {
    private func palette(opacity: Double, active: Bool) -> HomePaletteProbe {
        let scope = ThemeScope(level: .room)
        var input = ThemeScope.app.input
        input.backgroundOpacity = opacity
        scope.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        return scope.perform {
            HomePaletteProbe(scene: HomeThemePalette.resolveInScope(active: active).background, fill: Palette.paneFill)
        }
    }

    struct HomePaletteProbe {
        let scene: HomeColor
        let fill: NSColor
    }

    @Test(arguments: [true, false])
    func aSeeThroughWindowsHomePaintsNothing(_ active: Bool) {
        #expect(palette(opacity: 0.6, active: active).scene.alpha == 0)
    }

    @Test(arguments: [true, false])
    func anOpaqueWindowsHomePaintsThePaneFill(_ active: Bool) throws {
        let probe = palette(opacity: 1, active: active)
        let fill = try #require(probe.fill.usingColorSpace(.sRGB))
        #expect(probe.scene.alpha == 1)
        #expect(abs(probe.scene.red - fill.redComponent) < 0.002 && abs(probe.scene.green - fill.greenComponent) < 0.002
            && abs(probe.scene.blue - fill.blueComponent) < 0.002, "no inactive tint")
    }
}
