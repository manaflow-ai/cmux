import AppKit
import Testing
@testable import CmuxNextDesign

/// A Ghostty config reload reaches every chrome color live.
@MainActor @Suite(.serialized) struct ThemeStoreTests {
    final class Recorder: ThemeResponsive {
        var calls = 0
        func themeDidChange() { calls += 1 }
    }

    /// Records appearance callbacks, the hook every chrome view uses to
    /// re-resolve its layer colors.
    final class ProbeView: NSView {
        var appearanceCalls = 0
        var resolvedBackground: CGColor?
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            appearanceCalls += 1
            effectiveAppearance.performAsCurrentDrawingAppearance { resolvedBackground = Palette.sidebarBackground.cgColor }
        }
    }

    @Test func applyingANewThemeUpdatesTokensAndNotifiesResponders() {
        let store = ThemeStore(input: ThemeFixtures.catppuccinMocha)
        let recorder = Recorder()
        store.addResponder(recorder)
        #expect(store.apply(ThemeFixtures.gruvboxDark))
        #expect(store.tokens == ThemeTokens.derive(from: ThemeFixtures.gruvboxDark))
        #expect(store.generation == 1)
        #expect(recorder.calls == 1)
        // The same config again (a reload with no color change) is a no-op.
        #expect(!store.apply(ThemeFixtures.gruvboxDark))
        #expect(recorder.calls == 1)
        #expect(store.generation == 1)
    }

    @Test func darkToLightFlipsTheAppearance() {
        let store = ThemeStore(input: ThemeFixtures.monokaiClassic)
        #expect(store.appearance.name == .darkAqua)
        store.apply(ThemeFixtures.githubLight)
        #expect(store.appearance.name == .aqua)
    }

    /// End to end through the shared store: open windows get the new
    /// appearance, their views re-resolve (even dark to dark, where AppKit
    /// itself would not call the appearance hook), and `Palette` resolves
    /// to the new theme.
    @Test func sharedStoreReloadRepaintsOpenWindows() throws {
        let shared = ThemeStore.shared
        let original = shared.input
        defer { shared.apply(original) }
        shared.apply(ThemeFixtures.catppuccinMocha)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let probe = ProbeView(frame: NSRect(x: 0, y: 0, width: 50, height: 50))
        window.contentView.addSubview(probe)
        let before = probe.appearanceCalls

        #expect(shared.apply(ThemeFixtures.gruvboxDark))
        #expect(probe.appearanceCalls > before)
        #expect(window.appearance?.name == .darkAqua)
        let gruvbox = try #require(probe.resolvedBackground?.components)
        #expect(abs(gruvbox[0] - 0x28 / 255.0) < 0.002)

        #expect(shared.apply(ThemeFixtures.githubLight))
        #expect(window.appearance?.name == .aqua)
        let light = try #require(Palette.textPrimary.usingColorSpace(.sRGB))
        #expect(abs(light.redComponent - 0x1F / 255.0) < 0.002)
        window.close()
    }
}
