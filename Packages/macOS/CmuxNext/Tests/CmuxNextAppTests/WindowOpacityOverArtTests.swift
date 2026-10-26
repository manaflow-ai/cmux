import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
@testable import CmuxNextTerminal
import Foundation
import Testing

/// "The settings background opacity thing does not work very well" (a249): over a background
/// picture the Opacity slider must move the window one way only, and a surface's own opacity must
/// cover more than the tint the window really shows, not more than the theme's opaque 100%.
@MainActor @Suite(.serialized) struct WindowOpacityOverArtTests {
    static let work = "van-gogh-starry-night"

    static func ghostty() -> GhosttyThemeColors {
        let gray = GhosttyThemeColors.RGB(r: 0x80, g: 0x80, b: 0x80)
        return GhosttyThemeColors(background: .init(r: 0x20, g: 0x22, b: 0x28), foreground: .init(r: 0xF0, g: 0xF0, b: 0xF0),
                                  palette: Array(repeating: gray, count: 16), selectionBackground: nil, selectionForeground: nil,
                                  cursor: nil, backgroundOpacity: 1, backgroundBlur: 0)
    }

    /// The window opacity a scope shows for `backgroundOpacity` in cmux.json over the picture,
    /// applied the way the app applies it (`TerminalThemeSetting` on the scope it paints).
    func shownOpacity(_ backgroundOpacity: Double) async throws -> Double {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-opacity-art-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        let json = #"{"appearance": {"background": "\#(Self.work)", "backgroundOpacity": \#(backgroundOpacity)}}"#
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()

        let original = ThemeScope.app.store.input
        let colors = Self.ghostty()
        GhosttyConfigBackground.loaded = GhosttyConfigBackground(opacity: colors.backgroundOpacity, blur: colors.backgroundBlur)
        defer {
            GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
            GhosttyConfigBackground.loaded = GhosttyConfigBackground()
            ThemeScope.app.store.apply(original)
        }
        let scope = ThemeScope(level: .room)
        let terminal = TerminalThemeSetting(backdropScope: scope)
        terminal.reload = { ThemeScope.app.store.apply(ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride)) }
        terminal.follow(settings)
        ThemeScope.app.store.apply(ThemeBridge.input(colors, background: GhosttyRuntime.backgroundOverride))
        #expect(scope.backdropSelection?.id == Self.work)
        return scope.shownWindowOpacity
    }

    /// Dragging Opacity up over a picture never makes the window show more of the picture: the
    /// last step (100%) used to fall back to the work's own lighter tint.
    @Test func overAPictureMoreOpacityNeverShowsMoreOfThePicture() async throws {
        let steps = [0.8, 0.9, 0.95, 1.0]
        var shown: [Double] = []
        for step in steps { shown.append(try await shownOpacity(step)) }
        for (lower, higher) in zip(shown, shown.dropFirst()) {
            #expect(higher >= lower - 0.0001, "shown opacities \(shown) for \(steps)")
        }
        // 100% covers the picture fully: the window is opaque (2026-10-21, "all the way to 100%").
        #expect(shown[3] == 1, "shown opacities \(shown)")
    }

    /// A surface's own opacity over a picture covers the picture that much: the window shows the
    /// work's tint (well under 100%), so a 97% sidebar paints a fill on top of it. It used to paint
    /// nothing, measured against the theme's opaque 100%, and to read the app's surfaces instead
    /// of the scope's.
    @Test func overAPictureASurfaceOpacityCoversThePictureThatMuch() throws {
        let scope = ThemeScope(level: .room)
        let work = try #require(BackdropSelection(id: Self.work))
        scope.setBackdropSelection(work)
        scope.setSurfaceBackgrounds(SurfaceBackgrounds(overrides: [.sidebar: SurfaceBackground(opacity: 0.97)]))
        let window = scope.shownWindowOpacity
        #expect(window < 0.97)

        let fill = scope.perform { Palette.surfaceOverride(.sidebar) }
        let alpha = Double(try #require(fill).alphaComponent)
        #expect(alpha > 0)
        // Over the tint at `window`, the fill covers window + alpha * (1 - window).
        #expect(abs(window + alpha * (1 - window) - 0.97) < 0.01, "window \(window), fill alpha \(alpha)")
    }
}
