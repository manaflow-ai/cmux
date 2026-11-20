import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// #44894: with a theme file active that sets Plain Backgrounds on and the window Opacity, moving
/// Opacity (or turning Plain Backgrounds off) in Settings saved to cmux-next.json and changed
/// nothing: the file applied over the saved value. A Settings change now applies over the theme
/// file (`appearance.themeFileExceptions`), Reset returns to the file's value, and the page notes
/// say where a value comes from and why the window background does not draw.
@MainActor @Suite(.serialized) struct ThemeFileExceptionsTests {
    static let opacity = WindowBackgroundSetting.opacityPath
    static let reduced = ReducedBackgroundsSetting.configPath
    static let exceptions = ["appearance", "themeFileExceptions"]

    /// The reporter's files: the look exported into a theme file and that file active.
    static let theme = #"""
    { "ui.reducedBackgrounds": true, "appearance.backgroundOpacity": 0.85, "appearance.backgroundBlur": "glass-clear" }
    """#
    static let config = #"""
    { "ui": { "reducedBackgrounds": true },
      "appearance": { "themeFile": "tokyo", "backgroundOpacity": 0.85, "backgroundBlur": "glass-clear" } }
    """#

    func controller(_ home: ThemeFileTests.Home) async throws -> SettingsController {
        try home.write(Self.theme, theme: "tokyo")
        let settings = try ThemeFileTests.controller(home, config: Self.config)
        await settings.reload()
        return settings
    }

    func descriptor(_ path: [String]) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: path))
    }

    @Test func aSettingsChangeAppliesOverTheThemeFileAndResetReturnsToIt() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        #expect(settings.snapshot.reducedBackgrounds)

        // Plain Backgrounds off: its default, kept explicit so the file's `true` cannot apply again.
        try await settings.setSetting(descriptor(Self.reduced), to: false, by: .user)
        #expect(!settings.snapshot.reducedBackgrounds)
        #expect(settings.fileRoot.value(at: Self.reduced) == false)
        // At the default, the row still offers Reset back to the file's value.
        #expect(try settings.isCustomized(descriptor(Self.reduced)))

        try await settings.setSetting(descriptor(Self.opacity), to: 0.5, by: .user)
        #expect(settings.snapshot.windowBackground.opacity == 0.5)
        #expect(settings.snapshot.windowBackground.material == .glassClear)
        #expect(settings.fileRoot.value(at: Self.exceptions) == ["appearance.backgroundOpacity", "ui.reducedBackgrounds"])

        // Reset: the theme file's value applies again.
        try await settings.setSetting(descriptor(Self.opacity), to: nil, by: .user)
        #expect(settings.snapshot.windowBackground.opacity == 0.85)
        #expect(settings.fileRoot.value(at: Self.exceptions) == ["ui.reducedBackgrounds"])
        #expect(!settings.snapshot.reducedBackgrounds)
    }

    /// Settings > Background's No wallpaper tile writes `appearance.background` "none", the
    /// default, under a theme file that sets a painting: it applies live and stays after a reload.
    @Test func noWallpaperTurnsTheThemeFilesPictureOff() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        try home.write(#"{ "appearance.background": "bruegel-fall-rebel-angels" }"#, theme: "tokyo")
        let settings = try ThemeFileTests.controller(home, config: #"{ "appearance": { "themeFile": "tokyo" } }"#)
        await settings.reload()
        #expect(settings.snapshot.backdropSelection != nil)
        try await settings.setSetting(descriptor(BackdropSelectionSetting.configPath), to: "none", by: .user)
        #expect(settings.snapshot.backdropSelection == nil)
        #expect(settings.fileRoot.value(at: BackdropSelectionSetting.configPath) == "none")
        // A relaunch reads the same files.
        let relaunched = SettingsController(writer: TestSettingsWriter(), registry: .standard(), design: DesignSettings(),
                                                fileURL: home.config, managedReader: FixedManagedPreferenceReader(ManagedPreferences()),
                                                managedWatchFiles: [])
        await relaunched.reload()
        #expect(relaunched.snapshot.backdropSelection == nil)
    }

    @Test func choosingAnotherThemeFileAppliesItWhole() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        try await settings.setSetting(descriptor(Self.reduced), to: false, by: .user)
        #expect(settings.fileRoot.value(at: Self.exceptions) != nil)
        try home.write(#"{ "ui.reducedBackgrounds": true }"#, theme: "harbor")
        try await settings.setSetting(descriptor(ThemeFileSetting.configPath), to: "harbor", by: .user)
        #expect(settings.fileRoot.value(at: Self.exceptions) == nil)
        #expect(settings.snapshot.reducedBackgrounds)
    }

    @Test func thePageNotesWhereAValueComesFromAndWhyItDoesNotDraw() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        let notes = settings.pageNotes
        #expect(notes.contains { $0.kind == .plainBackgrounds && $0.path == "appearance.backgroundOpacity" })
        #expect(notes.contains { $0.kind == .setByThemeFile && $0.path == "appearance.backgroundOpacity" && $0.file == "themes/tokyo.json" })
        #expect(!settings.pageDiagnostics.contains { SettingsController.noteKinds.contains($0.kind) })

        try await settings.setSetting(descriptor(Self.reduced), to: false, by: .user)
        #expect(!settings.pageNotes.contains { $0.kind == .plainBackgrounds })
        #expect(settings.pageNotes.contains { $0.kind == .overThemeFile && $0.path == "ui.reducedBackgrounds" })
    }
}
