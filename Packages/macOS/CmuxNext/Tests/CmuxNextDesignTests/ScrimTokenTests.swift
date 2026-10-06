import AppKit
@testable import CmuxNextDesign
import Testing

/// Leo (2026-10-06): popups darkened the window too much. Every modal scrim
/// (native dialogs and the web pages' sheets) reads one token, about the
/// Codex desktop app's: black at 12% in a light theme, 25% in a dark one.
/// Popovers anchored to a control draw no scrim.
@MainActor @Suite struct ScrimTokenTests {
    @Test func theTokenIsLightInBothThemes() {
        #expect(Scrim.alpha(isDark: false) == 0.12)
        #expect(Scrim.alpha(isDark: true) == 0.25)
    }

    @Test func pagesGetTheTokenForTheirTheme() {
        let light = ThemeTokens.derive(from: ThemeFixtures.githubLight)
        let dark = ThemeTokens.derive(from: ThemeFixtures.catppuccinMocha)
        #expect(WebTheme(light).variables["--cmux-scrim"] == "rgba(0, 0, 0, 0.12)")
        #expect(WebTheme(dark).variables["--cmux-scrim"] == "rgba(0, 0, 0, 0.25)")
    }

    @Test func aWindowDialogsScrimUsesTheToken() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let scrim = OverlayScrimView(frame: host.bounds)
        host.addSubview(scrim)
        scrim.appearance = NSAppearance(named: .aqua)
        scrim.updateLayer()
        let alpha = scrim.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? -1
        #expect(alpha == Scrim.alpha(isDark: (ThemeContext.active ?? ThemeScope.app.tokens).isDark))
        #expect(alpha <= 0.25)
    }

    @Test func anchoredPopoversDrawNoScrim() {
        #expect(!OverlayOptions(kind: .popover).dimsContent)
        #expect(!OverlayOptions(kind: .attached).dimsContent)
    }
}
