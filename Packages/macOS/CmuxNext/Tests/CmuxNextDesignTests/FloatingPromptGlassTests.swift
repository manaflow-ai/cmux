import AppKit
import CmuxNextTestSupport
import CmuxTheme
@testable import CmuxNextDesign
import CmuxNextDesignTokens
import Testing

/// A prompt that floats over every app (the join consent, a device asking to control this Mac, Computer use acting as
/// me) draws the ``SurfaceRole/prompt`` glass: the theme's tint, never the bare system glass the gray sheet veil left
/// it on (Leo 2026-11-22: "im not sure what was up with the glass on it, and the lack of theming on it too"). Any
/// app shows under it, so its text is fit over a white and a black page, in every bundled theme.
@MainActor @Suite(.serialized, .closesItsWindows)
struct FloatingPromptGlassTests {
    @Test func thePromptRoleIsTheThemesTintAndStaysGlass() {
        let style = FloatingGlassStyle.prompt
        #expect(SurfaceRole.prompt.neutralStyle == .prompt)
        #expect(style.veilTakesThemeTint)
        #expect(style.castsShadow)
        // Liquid Glass as picked tints a style only when its veil is the theme's (the sheet's gray is dropped).
        #expect(OverlayGlassVariant.picked.tintsGlass(style))
        for isDark in [false, true] {
            #expect(style.look(isDark: isDark).veil.alpha < SurfaceRole.nearOpaque)
            // Denser than the in-window dialogs' transient veil: what shows through is another app, not a scrim.
            #expect(style.look(isDark: isDark).veil.alpha > FloatingGlassStyle.transient.look(isDark: isDark).veil.alpha)
        }
    }

    /// The floating panel's card and the consents' host view draw the prompt glass; a card over its anchor window keeps
    /// the spec's.
    @Test func floatingCardsDrawThePromptGlass() throws {
        _ = NSApplication.shared
        let spec = CmuxDialogSpec(title: "Allow control?", lines: ["A computer on your team asks."],
                                  buttons: [CmuxDialogButton(id: "ok", title: "OK", role: .default)])
        let host = CmuxDialogHostView(frame: .zero)
        let card = try #require(host.draw(spec) { _ in }.surface)
        #expect(card.glass.tone.style == .prompt)
        let inWindow = try #require(CmuxDialogView(dialog: .standalone(spec) { _ in }).surface)
        #expect(inWindow.glass.tone.style != .prompt)
    }

    @Test func promptTextReadsOverAnyAppInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let scope = ThemeScope(level: .room)
        var failures: [String] = []
        for theme in themes {
            scope.setOverride(try #require(ThemeSpec("Prompt \(theme.name)")), input: theme.input, animated: false)
            let tokens = scope.tokens
            let surfaces = CmuxDialogButtonLook.promptCardSurfaces(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            for ink in [ThemeInk.primary, .secondary] {
                let fitted = CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: surfaces, minimum: ink.minimumContrast)
                if !CmuxDialogButtonLook.fits(fitted, over: surfaces, minimum: ink.minimumContrast - 0.01) {
                    failures.append("\(theme.label): \(ink)")
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(40).joined(separator: "\n")))
    }
}
