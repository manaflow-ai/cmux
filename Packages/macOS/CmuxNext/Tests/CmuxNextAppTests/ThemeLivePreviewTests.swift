import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
@testable import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// A theme previews live in the app without a write (cx-wqn5: hover, the arrow keys or right-click >
/// Preview in a theme picker; Esc reverts). `cmux.settings.preview` of `appearance.theme` puts the
/// theme on the terminals and of `appearance.appTheme` on the chrome; ending the preview restores
/// the saved ones, and the file never changes.
@MainActor @Suite(.serialized) struct ThemeLivePreviewTests {
    func make() async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-theme-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"appearance":{"theme":"Nord"}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, url)
    }

    func descriptor(_ key: String) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: key.split(separator: ".").map(String.init)))
    }

    /// Waits for the observers (`ObservationStream`) to see a change.
    func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    @Test func previewingATerminalThemeShowsItAndEndingRevertsIt() async throws {
        let (settings, url) = try await make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        var reloads = 0
        terminal.reload = { reloads += 1 }
        terminal.follow(settings)
        #expect(GhosttyRuntime.themeOverride == "Nord")

        #expect(settings.preview(try descriptor("appearance.theme"), .string("Rose Pine")))
        await settle { GhosttyRuntime.themeOverride == "Rose Pine" }
        #expect(GhosttyRuntime.themeOverride == "Rose Pine")
        #expect(reloads > 0)

        settings.endPreview()
        await settle { GhosttyRuntime.themeOverride == "Nord" }
        #expect(GhosttyRuntime.themeOverride == "Nord")
        #expect(try String(contentsOf: url, encoding: .utf8).contains("Nord"))
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("Rose Pine"))
    }

    /// Only the theme previews on the terminals: a slider's preview (font size) never reloads the
    /// Ghostty config on every step of the drag.
    @Test func aSliderPreviewDoesNotReloadTheTerminals() async throws {
        let (settings, url) = try await make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let terminal = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        var reloads = 0
        terminal.reload = { reloads += 1 }
        terminal.follow(settings)
        let before = reloads
        for size in [14.0, 15, 16] {
            #expect(settings.preview(try descriptor("terminal.fontSize"), .number(size)))
            for _ in 0..<50 { await Task.yield() }
        }
        #expect(reloads == before)
        settings.endPreview()
    }

    /// The Hue and Saturation sliders preview while you drag them, like Opacity: the window's tint
    /// follows the previewed value before the release writes it, and ending the preview reverts it.
    @Test func previewingHueTintsTheWindowBeforeItIsSaved() async throws {
        let (settings, url) = try await make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data(#"{"appearance":{"theme":"Nord","experimentalControls":true}}"#.utf8).write(to: url)
        await settings.reload()
        let scope = ThemeScope(level: .room)
        let terminal = TerminalThemeSetting(backdropScope: scope)
        terminal.reload = {}
        terminal.follow(settings)
        #expect(scope.appearanceTuning.hue == AppearanceTuning.identity.hue)

        #expect(settings.preview(try descriptor("appearance.hue"), .number(0.8)))
        await settle { scope.appearanceTuning.hue == 0.8 }
        #expect(scope.appearanceTuning.hue == 0.8)
        #expect(settings.snapshot.appearanceTuning.hue == AppearanceTuning.identity.hue)

        settings.endPreview()
        await settle { scope.appearanceTuning.hue == AppearanceTuning.identity.hue }
        #expect(scope.appearanceTuning.hue == AppearanceTuning.identity.hue)
        // The stream holds the setting weakly: keep it alive through the last check.
        withExtendedLifetime(terminal) {}
    }

    @Test func previewingAnAppThemeReachesTheChromeAndEndingRevertsIt() async throws {
        let (settings, url) = try await make()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(settings.applied.chromeTheme == nil)
        #expect(settings.preview(try descriptor("appearance.appTheme"), .string("Rose Pine")))
        #expect(settings.applied.chromeTheme == "Rose Pine")
        #expect(settings.snapshot.chromeTheme == nil)
        settings.endPreview()
        #expect(settings.applied.chromeTheme == nil)
    }
}
