import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

/// `applyTerminalTheme` is the consumer seam: a connect adopts the Mac's
/// reported theme into the shell-owned active theme,
/// then bumps the generation only when the resolved theme actually changes, so an
/// unchanged reconnect does not needlessly recreate the surface (which would
/// lose scrollback).
@MainActor
@Suite(.serialized) struct TerminalThemeApplyTests {
    private func makeTheme(background: String) -> TerminalTheme {
        var theme = TerminalTheme.monokai
        theme.background = background
        return theme
    }

    @Test func applyingNewThemeBumpsGenerationAndUpdatesActiveTheme() {
        let store = MobileShellComposite()
        let start = store.terminalThemeGeneration

        let custom = makeTheme(background: "#101010")
        store.applyTerminalTheme(custom)

        #expect(store.terminalThemeGeneration == start &+ 1)
        #expect(store.activeTerminalTheme == custom)
    }

    @Test func applyingSameThemeDoesNotBumpGeneration() {
        let custom = makeTheme(background: "#202020")
        let store = MobileShellComposite()
        store.applyTerminalTheme(custom)
        let start = store.terminalThemeGeneration

        // Re-applying the identical theme (a steady-state reconnect) must not
        // remount the surface.
        store.applyTerminalTheme(custom)

        #expect(store.terminalThemeGeneration == start)
        #expect(store.activeTerminalTheme == custom)
    }

    @Test func applyingNilThemeResolvesToMonokai() {
        let custom = makeTheme(background: "#303030")
        let store = MobileShellComposite()
        store.applyTerminalTheme(custom)
        let start = store.terminalThemeGeneration

        // An older Mac omits the field; the store resolves nil to Monokai, which
        // differs from the custom theme, so the surface remounts.
        store.applyTerminalTheme(nil)

        #expect(store.terminalThemeGeneration == start &+ 1)
        #expect(store.activeTerminalTheme == .monokai)
    }
}
