import AppKit
import CmuxHomeRender
@testable import CmuxNextDesign
import CmuxNextDesignTokens
@testable import CmuxNextHome
import Testing

/// Home's search capsule over a see-through window. The capsule is clear button glass, so over art
/// its placeholder (the secondary text) read at 2.05:1 on the Great Wave in dark (fleet capture of
/// be805d96, text-inputs-glass/states.py, home-search art). Over a see-through Home fill the capsule
/// takes the fill every other field takes there (the web composer's surface, the Chief field's
/// `composeFillOverGlass`); an opaque Home fill keeps the clear glass.
@MainActor @Suite struct HomeSearchCapsuleFillTests {
    nonisolated static let themes: [ThemeInput] = [
        ThemeInput(background: ThemeRGB(hex: 0xFFFFFF), foreground: ThemeRGB(hex: 0x1F2328)),
        ThemeInput(background: ThemeRGB(hex: 0x1E1E1E), foreground: ThemeRGB(hex: 0xE6E6E6)),
    ]

    private func tint(_ theme: ThemeInput, homeAlpha: Double) -> (NSColor?, HomeColor) {
        let store = ThemeStore()
        let app = ThemeScope(root: store)
        store.apply(theme)
        app.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.home: SurfaceBackground(color: theme.background.withAlpha(1), opacity: homeAlpha)]))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        app.root(host)
        return host.performWithTheme {
            let palette = HomeThemePalette.resolveInScope(active: true, style: .iMessage)
            return (HomeSidebarView.searchCapsuleTintInScope(), palette.composeFillOverGlass ?? HomeColor(red: 0, green: 0, blue: 0, alpha: 0))
        }
    }

    @Test(arguments: themes)
    func seeThroughHomeFillGivesTheCapsuleTheComposerSurface(_ theme: ThemeInput) throws {
        let (capsule, field) = tint(theme, homeAlpha: 0)
        let c = try #require(capsule?.usingColorSpace(.sRGB))
        #expect(abs(c.redComponent - field.red) < 0.002 && abs(c.greenComponent - field.green) < 0.002
                && abs(c.blueComponent - field.blue) < 0.002 && abs(c.alphaComponent - field.alpha) < 0.002)
    }

    @Test(arguments: themes)
    func opaqueHomeFillKeepsTheClearCapsule(_ theme: ThemeInput) {
        #expect(tint(theme, homeAlpha: 1).0 == nil)
    }
}
