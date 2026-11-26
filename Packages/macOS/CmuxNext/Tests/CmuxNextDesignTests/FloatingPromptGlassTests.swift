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
        try DesignSettings.$themedPromptsOverride.withValue(true) { try floatingCardsDrawThePromptGlassOn() }
    }

    private func floatingCardsDrawThePromptGlassOn() throws {
        _ = NSApplication.shared
        let spec = CmuxDialogSpec(title: "Allow control?", lines: ["A computer on your team asks."],
                                  buttons: [CmuxDialogButton(id: "ok", title: "OK", role: .default)])
        let host = CmuxDialogHostView(frame: .zero)
        let card = try #require(host.draw(spec) { _ in }.surface)
        #expect(card.glass.tone.style == .prompt)
        let inWindow = try #require(CmuxDialogView(dialog: .standalone(spec) { _ in }).surface)
        #expect(inWindow.glass.tone.style != .prompt)
    }

    /// A floating prompt names who asks in its header (the icon small beside the title) and keeps the text column the
    /// card's width; a dialog in a window keeps the large icon at the left.
    @Test func floatingCardsLeadWithAnIdentityHeader() throws {
        try DesignSettings.$themedPromptsOverride.withValue(true) { try floatingCardsLeadWithAnIdentityHeaderOn() }
    }

    /// Off (Settings > Experiments > Themed Floating Prompts, the default), a floating card keeps the large icon at
    /// the left, as before.
    @Test func offAFloatingCardKeepsTheLargeIcon() throws {
        _ = NSApplication.shared
        try DesignSettings.$themedPromptsOverride.withValue(false) {
            let spec = CmuxDialogSpec(title: "Desk Mac asked to control this Mac.", lines: ["Allow control?"],
                                      buttons: [CmuxDialogButton(id: "ok", title: "OK", role: .default)])
            let floating = CmuxDialogView(dialog: .standalone(spec) { _ in }, overApps: true)
            floating.layoutSubtreeIfNeeded()
            #expect(!floating.overApps)
            func icons(_ view: NSView) -> [NSImageView] {
                view.subviews.flatMap { ($0 as? NSImageView).map { [$0] } ?? icons($0) }
            }
            #expect(icons(floating).map(\.frame.width) == [CmuxDialogMetrics.iconSize])
            let surface = try #require(floating.surface)
            #expect(surface.glass.tone.style != .prompt)
        }
    }

    private func floatingCardsLeadWithAnIdentityHeaderOn() throws {
        _ = NSApplication.shared
        let spec = CmuxDialogSpec(title: "Desk Mac asked to control this Mac.", lines: ["Allow control?", "You can change this later."],
                                  buttons: [CmuxDialogButton(id: "ok", title: "OK", role: .default)])
        let floating = CmuxDialogView(dialog: .standalone(spec) { _ in }, overApps: true)
        let inWindow = CmuxDialogView(dialog: .standalone(spec) { _ in })
        floating.layoutSubtreeIfNeeded()
        inWindow.layoutSubtreeIfNeeded()
        func icons(_ view: NSView) -> [NSImageView] {
            view.subviews.flatMap { ($0 as? NSImageView).map { [$0] } ?? icons($0) }
        }
        #expect(icons(floating).map(\.frame.width) == [CmuxDialogMetrics.headerIconSize])
        #expect(icons(inWindow).map(\.frame.width) == [CmuxDialogMetrics.iconSize])
        #expect(floating.fittingSize.width == CmuxDialogMetrics.width)
    }

    /// Mid-tone dark themes whose glass tint at the prompt's veil leaves no one ink that reads at 4.5:1 over both a white
    /// and a black page (as ``CmuxDialogButtonLook/readable(_:over:minimum:)`` says of Hot Dog Stand's red): their text
    /// still reads on the theme's own window and the opaque surface, and takes the pole that reads on the most pages.
    static let midTone: Set<String> = ["Blue Dolphin", "Fairyfloss", "Grass", "Hot Dog Stand", "Ocean", "Seoulbones Dark"]

    @Test func promptTextReadsOverAnyAppInEveryBundledTheme() throws {
        let themes = try CardNeverOpaqueTests.bundledThemes()
        #expect(themes.count > 600)
        let scope = ThemeScope(level: .room)
        var failures: [String] = []
        for theme in themes {
            scope.setOverride(try #require(ThemeSpec("Prompt \(theme.name)")), input: theme.input, animated: false)
            let tokens = scope.tokens
            let surfaces = CmuxDialogButtonLook.promptCardSurfaces(tokens, lift: ChromeTunables.opaqueOverlayLift.value)
            // The prompt over the theme's own window and the Reduce Transparency surface always read.
            let checked = Self.midTone.contains(theme.name) ? Array(surfaces.prefix(2)) : surfaces
            for ink in [ThemeInk.primary, .secondary] {
                let fitted = CmuxDialogButtonLook.readable(ink.rgb(tokens).withAlpha(1), over: surfaces, minimum: ink.minimumContrast)
                if !CmuxDialogButtonLook.fits(fitted, over: checked, minimum: ink.minimumContrast - 0.01) {
                    failures.append("\(theme.label): \(ink)")
                }
            }
        }
        #expect(failures.isEmpty, Comment(rawValue: "\(failures.count) failures; first:\n" + failures.prefix(40).joined(separator: "\n")))
    }
}
