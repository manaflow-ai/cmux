import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// #44894, the reporter's own files: Plain Backgrounds on in cmux-next.json itself (no theme file
/// entry). Settings > Opacity at 80% saved `appearance.backgroundOpacity: 0.8` and the window stayed
/// opaque, because Plain Backgrounds draws every window plain. The person's see-through Opacity or
/// Material now turns Plain Backgrounds off with the write, so the value saves and draws.
@MainActor @Suite(.serialized) struct PlainBackgroundsOpacityTests {
    static let opacity = WindowBackgroundSetting.opacityPath
    static let material = WindowBackgroundSetting.materialPath
    static let reduced = ReducedBackgroundsSetting.configPath

    /// The reporter's cmux-next.json: Plain Backgrounds on, an active theme file that sets nothing.
    static let config = #"""
    { "ui": { "reducedBackgrounds": true, "animations": { "enabled": false } },
      "appearance": { "themeFile": "my-look", "backgroundOpacity": 0.85, "backgroundBlur": "none" } }
    """#

    func controller(_ home: ThemeFileTests.Home, theme: String = #"{ "name": "my-look" }"#) async throws -> SettingsController {
        try home.write(theme, theme: "my-look")
        let settings = try ThemeFileTests.controller(home, config: Self.config)
        await settings.reload()
        return settings
    }

    func descriptor(_ path: [String]) throws -> SettingDescriptor {
        try #require(SettingsSchema.descriptor(for: path))
    }

    /// What the window draws: the snapshot's background through Plain Backgrounds.
    func drawn(_ settings: SettingsController) -> WindowBackgroundOverride {
        ReducedBackgroundsSetting.drawn(settings.snapshot.windowBackground, reduced: settings.snapshot.reducedBackgrounds)
    }

    @Test func opacityAt80PercentSavesAndDraws() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        #expect(drawn(settings).opacity == 1)

        try await settings.setSetting(descriptor(Self.opacity), to: 0.8, by: .user)
        #expect(settings.fileRoot.value(at: Self.opacity) == 0.8)
        #expect(!settings.snapshot.reducedBackgrounds)
        // Off is the default: the key goes, the rest of `ui` stays.
        #expect(settings.fileRoot.value(at: Self.reduced) == nil)
        #expect(settings.fileRoot.value(at: ["ui", "animations", "enabled"]) == false)
        #expect(drawn(settings).opacity == 0.8)
        #expect(settings.pageNotes.allSatisfy { $0.kind != .plainBackgrounds })

        // A relaunch reads the same file and draws the same window.
        let relaunched = try ThemeFileTests.controller(home, config: String(decoding: Data(contentsOf: home.config), as: UTF8.self))
        await relaunched.reload()
        #expect(drawn(relaunched).opacity == 0.8)
    }

    @Test func aBlurTurnsPlainBackgroundsOffAndAnOpaqueWriteKeepsIt() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        // Opaque and unblurred is what Plain Backgrounds draws anyway: it stays on.
        try await settings.setSetting(descriptor(Self.opacity), to: 1, by: .user)
        #expect(settings.snapshot.reducedBackgrounds)
        try await settings.setSetting(descriptor(Self.material), to: "glass-clear", by: .user)
        #expect(!settings.snapshot.reducedBackgrounds)
        #expect(drawn(settings).material == .glassClear)
    }

    @Test func anAgentWriteLeavesThePersonsPlainBackgroundsOn() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home)
        let descriptor = try descriptor(Self.opacity)
        guard SettingWriter.caller("agent").mayWrite(descriptor) else { return }
        try await settings.setSetting(descriptor, to: 0.8, by: .caller("agent"))
        #expect(settings.snapshot.reducedBackgrounds)
    }

    /// A theme file that turns Plain Backgrounds on: the write keeps an explicit `false` over it.
    @Test func overAThemeFilesPlainBackgroundsTheWriteKeepsOff() async throws {
        let home = try ThemeFileTests.Home()
        defer { withExtendedLifetime(home) {} }
        let settings = try await controller(home, theme: #"{ "ui.reducedBackgrounds": true }"#)
        try await settings.setSetting(descriptor(Self.opacity), to: 0.8, by: .user)
        #expect(!settings.snapshot.reducedBackgrounds)
        #expect(settings.fileRoot.value(at: Self.reduced) == false)
        #expect(settings.fileRoot.value(at: ["appearance", "themeFileExceptions"]) == ["ui.reducedBackgrounds"])
        #expect(drawn(settings).opacity == 0.8)
    }
}
