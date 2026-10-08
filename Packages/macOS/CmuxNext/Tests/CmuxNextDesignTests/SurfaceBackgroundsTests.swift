import AppKit
@testable import CmuxNextDesign
import Testing

/// Lawrence R55: every surface matches the window by default and each one
/// may take its own color and opacity. One resolver
/// (`SurfaceBackgrounds.fill`) gives every owner what it paints over the
/// window's one backdrop.
@MainActor @Suite(.serialized) struct SurfaceBackgroundsTests {
    static let red = ThemeRGB(red: 0.8, green: 0.2, blue: 0.2)

    static func tokens(opacity: Double) -> ThemeTokens {
        var input = ThemeFixtures.catppuccinMocha
        input.backgroundOpacity = opacity
        return ThemeTokens.derive(from: input)
    }

    @Test(arguments: SurfaceKind.allCases)
    func noOverrideKeepsTheWindowBackdrop(_ kind: SurfaceKind) {
        for opacity in [1.0, 0.8, 0.5] {
            #expect(SurfaceBackgrounds.none.fill(for: kind, tokens: Self.tokens(opacity: opacity)) == nil)
        }
        let other = SurfaceBackgrounds(overrides: [kind == .sidebar ? .terminal : .sidebar: SurfaceBackground(color: Self.red)])
        #expect(other.fill(for: kind, tokens: Self.tokens(opacity: 1)) == nil, "an override of another surface leaks into \(kind)")
    }

    @Test func aColorTakesTheWindowOpacityUnlessItHasItsOwn() {
        let backgrounds = SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(color: Self.red)])
        #expect(backgrounds.fill(for: .sidebar, tokens: Self.tokens(opacity: 1)) == Self.red)
        #expect(backgrounds.fill(for: .sidebar, tokens: Self.tokens(opacity: 0.8)) == Self.red.withAlpha(0.8))
        let own = SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(color: Self.red, opacity: 0.5)])
        #expect(own.fill(for: .sidebar, tokens: Self.tokens(opacity: 0.8)) == Self.red.withAlpha(0.5))
        let alpha = SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(color: Self.red.withAlpha(0.5), opacity: 0.5)])
        #expect(alpha.fill(for: .sidebar, tokens: Self.tokens(opacity: 1)) == Self.red.withAlpha(0.25))
    }

    /// Opacity alone: the surface covers the backdrop exactly that much,
    /// never less than the window does (the tint is under every surface).
    @Test func anOpacityAloneCoversTheBackdropThatMuch() throws {
        let tokens = Self.tokens(opacity: 0.5)
        let opaque = SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(opacity: 1)])
        let fill = try #require(opaque.fill(for: .terminal, tokens: tokens))
        #expect(fill.alpha == 1)
        let threeQuarters = try #require(SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(opacity: 0.75)])
            .fill(for: .terminal, tokens: tokens))
        #expect(abs(0.5 + threeQuarters.alpha * 0.5 - 0.75) < 1e-9)
        for lower in [0.5, 0.2, 0] {
            let fill = SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(opacity: lower)]).fill(for: .terminal, tokens: tokens)
            #expect(fill?.alpha == 0, "opacity \(lower) under a 0.5 window")
        }
        let inOpaqueWindow = SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(opacity: 0.3)])
        #expect(inOpaqueWindow.fill(for: .terminal, tokens: Self.tokens(opacity: 1))?.alpha == 0)
    }

    @Test func aDockStaysOpaque() {
        let tokens = Self.tokens(opacity: 0.8)
        let base = tokens.surfaceBackground.withAlpha(1)
        #expect(SurfaceBackgrounds.none.opaqueFill(for: .docks, tokens: tokens, base: base) == base)
        let half = SurfaceBackgrounds(overrides: [.docks: SurfaceBackground(color: Self.red, opacity: 0.5)])
        #expect(half.opaqueFill(for: .docks, tokens: tokens, base: base).alpha == 1)
    }

    /// The app scope's backgrounds reach `Palette` in any scope and are
    /// reset after the test.
    @Test func paletteReadsTheAppScope() throws {
        defer { ThemeScope.app.setSurfaceBackgrounds(.none) }
        ThemeScope.app.setSurfaceBackgrounds(.none)
        #expect(Palette.surfaceOverride(.home) == nil)
        ThemeScope.app.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.home: SurfaceBackground(color: Self.red, opacity: 1)]))
        let color = try #require(Palette.surfaceOverride(.home)?.usingColorSpace(.sRGB))
        #expect(abs(color.redComponent - 0.8) < 0.002 && color.alphaComponent == 1)
        #expect(Palette.surfaceOverride(.sidebar) == nil)
        let room = ThemeScope(level: .room)
        #expect(room.surfaceBackgrounds == ThemeScope.app.surfaceBackgrounds)
    }

    @Test func aWebPageTakesItsSurfacesOverride() {
        let tokens = Self.tokens(opacity: 1)
        let backgrounds = SurfaceBackgrounds(overrides: [.newTabPage: SurfaceBackground(color: Self.red)])
        let page = WebTheme(tokens, surface: .newTabPage, backgrounds: backgrounds).variables["--cmux-surface-background"]
        #expect(page == "rgba(204, 51, 51, 1.0)")
        let chat = WebTheme(tokens, surface: .agentPane, backgrounds: backgrounds).variables["--cmux-surface-background"]
        #expect(chat == WebTheme(tokens).variables["--cmux-surface-background"])
    }

    /// The diff viewer reads `--cmux-surface-background`; its own override
    /// reaches it, and a host surface's override does not.
    @Test func theDiffViewerTakesItsOwnOverride() {
        let tokens = Self.tokens(opacity: 0.8)
        let diff = SurfaceBackgrounds(overrides: [.diff: SurfaceBackground(color: Self.red, opacity: 1)])
        #expect(WebTheme(tokens, surface: .diff, backgrounds: diff).variables["--cmux-surface-background"] == "rgba(204, 51, 51, 1.0)")
        let host = SurfaceBackgrounds(overrides: [.terminal: SurfaceBackground(color: Self.red)])
        #expect(WebTheme(tokens, surface: .diff, backgrounds: host).variables["--cmux-surface-background"]
            == WebTheme(tokens).variables["--cmux-surface-background"])
    }

    /// The markdown and code editor pages (diff-host S6, S7) read `--cmux-surface-background` too,
    /// each with its own override.
    @Test func theFilePagesTakeTheirOwnOverrides() {
        let tokens = Self.tokens(opacity: 0.8)
        let markdown = SurfaceBackgrounds(overrides: [.markdown: SurfaceBackground(color: Self.red, opacity: 1)])
        #expect(WebTheme(tokens, surface: .markdown, backgrounds: markdown).variables["--cmux-surface-background"] == "rgba(204, 51, 51, 1.0)")
        #expect(WebTheme(tokens, surface: .editor, backgrounds: markdown).variables["--cmux-surface-background"]
            == WebTheme(tokens).variables["--cmux-surface-background"])
        let editor = SurfaceBackgrounds(overrides: [.editor: SurfaceBackground(color: Self.red, opacity: 1)])
        #expect(WebTheme(tokens, surface: .editor, backgrounds: editor).variables["--cmux-surface-background"] == "rgba(204, 51, 51, 1.0)")
        #expect(SurfaceKind(rawValue: "markdown") == .markdown && SurfaceKind(rawValue: "editor") == .editor)
    }
}
