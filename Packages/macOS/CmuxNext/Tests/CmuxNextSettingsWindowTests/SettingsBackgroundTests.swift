import AppKit
import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
@testable import CmuxNextSettingsWindow
import Testing

/// One backdrop rule (plans/cmux-next/windows.md, coordinator 2026-10-03):
/// the Settings window shows the main window's backdrop, the same material
/// and tint at the theme's opacity, and its SwiftUI root paints nothing of
/// its own over it.
@MainActor @Suite(.serialized) struct SettingsBackgroundTests {
    @Test func settingsShowsTheMainWindowsBackdropOverATranslucentTheme() async throws {
        var input = ThemeScope.app.input
        input.backgroundOpacity = 0.6
        let room = ThemeScope(level: .room)
        room.setOverride(ThemeSpec("Catppuccin Mocha")!, input: input, animated: false)
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-bg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let registry = ActionRegistry(catalog: [])
        let settings = SettingsController(registry: registry, design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(.empty), managedWatchFiles: [])
        await settings.reload()
        let controller = SettingsWindowController(model: SettingsWindowModel(settings: settings, registry: registry, host: nil))
        controller.setThemeScope(room)
        defer { controller.setThemeScope(.app) }
        let window = try #require(controller.window)
        let surface = try #require(window.contentView as? WindowSurfaceView)
        #expect(window.windowKind == .settings)
        #expect(!window.isOpaque, "the same see-through backdrop as the main window")
        let tint = try #require(surface.backdropView.tintColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let token = room.tokens.surfaceBackground
        #expect(abs(tint.alphaComponent - 0.6) < 0.01)
        #expect(abs(tint.redComponent - token.red) < 0.01 && abs(tint.greenComponent - token.green) < 0.01
            && abs(tint.blueComponent - token.blue) < 0.01)
        #expect(surface.layer?.backgroundColor == nil, "no solid sheet over the material")
    }
}
