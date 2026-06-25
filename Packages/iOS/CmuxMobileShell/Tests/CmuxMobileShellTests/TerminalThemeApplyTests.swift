import CMUXMobileCore
import Foundation
import Testing

@testable import CmuxMobileShell

/// `applyTerminalTheme` is the consumer seam: a connect adopts the Mac's
/// reported theme into the process-wide `TerminalThemeStore` and bumps the
/// remount generation only when the resolved theme actually changes, so an
/// unchanged reconnect does not needlessly recreate the surface (which would
/// lose scrollback).
@MainActor
@Suite struct TerminalThemeApplyTests {
    private func makeTheme(background: String) -> TerminalTheme {
        var theme = TerminalTheme.monokai
        theme.background = background
        return theme
    }

    @Test func applyingNewThemeBumpsGenerationAndUpdatesStore() {
        defer { TerminalThemeStore.set(.monokai) }
        TerminalThemeStore.set(.monokai)
        let store = MobileShellComposite()
        let start = store.terminalThemeGeneration

        let custom = makeTheme(background: "#101010")
        store.applyTerminalTheme(custom)

        #expect(store.terminalThemeGeneration == start &+ 1)
        #expect(TerminalThemeStore.current == custom)
    }

    @Test func applyingSameThemeDoesNotBumpGeneration() {
        defer { TerminalThemeStore.set(.monokai) }
        let custom = makeTheme(background: "#202020")
        TerminalThemeStore.set(custom)
        let store = MobileShellComposite()
        let start = store.terminalThemeGeneration

        // Re-applying the identical theme (a steady-state reconnect) must not
        // remount the surface.
        store.applyTerminalTheme(custom)

        #expect(store.terminalThemeGeneration == start)
        #expect(TerminalThemeStore.current == custom)
    }

    @Test func applyingNilThemeResolvesToMonokai() {
        defer { TerminalThemeStore.set(.monokai) }
        let custom = makeTheme(background: "#303030")
        TerminalThemeStore.set(custom)
        let store = MobileShellComposite()
        let start = store.terminalThemeGeneration

        // An older Mac omits the field; the store resolves nil to Monokai, which
        // differs from the custom theme, so the surface remounts.
        store.applyTerminalTheme(nil)

        #expect(store.terminalThemeGeneration == start &+ 1)
        #expect(TerminalThemeStore.current == .monokai)
    }
}
