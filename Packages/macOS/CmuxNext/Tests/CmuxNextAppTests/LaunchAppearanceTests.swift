import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import CmuxNextTerminal
import Foundation
import Testing

/// The first window draws in cmux.json's appearance: the file's theme and
/// background apply before launch goes on, never a frame of the defaults
/// first (sweep 4a: one dark frame without art before a light theme).
@MainActor
@Suite(.serialized) struct LaunchAppearanceTests {
    private static func settings(_ json: String) throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cmux-launch-appearance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        return (SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url), directory)
    }

    @Test func startAppliesTheFileBeforeItReturns() throws {
        let (settings, directory) = try Self.settings(#"{"appearance":{"background":"wheat-field-with-cypresses"}}"#)
        defer { settings.stop(); try? FileManager.default.removeItem(at: directory) }
        settings.start()
        #expect(settings.snapshot.backdropSelection == .art(.wheatField))
    }

    @Test func theBackdropFollowsTheLoadedFileAtOnce() throws {
        let (settings, directory) = try Self.settings(#"{"appearance":{"background":"wheat-field-with-cypresses"}}"#)
        defer { settings.stop(); try? FileManager.default.removeItem(at: directory) }
        settings.start()
        let scope = ThemeScope(level: .room)
        let follower = TerminalThemeSetting(backdropScope: scope)
        follower.follow(settings)
        #expect(scope.backdropSelection == .art(.wheatField))
    }

    /// The terminal runtime starts before the controller exists; launch
    /// reads the file once for both.
    @Test func theControllerAdoptsTheLaunchReadWithoutReadingAgain() throws {
        let (unused, directory) = try Self.settings(#"{"appearance":{"background":"wheat-field-with-cypresses"}}"#)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = unused.file.url
        let launch = SettingsController.readAtLaunch(fileURL: url)
        #expect(launch.snapshot.backdropSelection == .art(.wheatField))
        try FileManager.default.removeItem(at: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url, launch: launch)
        defer { settings.stop() }
        settings.start()
        #expect(settings.snapshot.backdropSelection == .art(.wheatField))
    }

    /// Sweep 4a: the first apply's config reload cost the first frame
    /// about 28 ms; a primed runtime already has the file's appearance.
    @Test func aPrimedRuntimeSkipsTheFirstReload() throws {
        let theme = "Apple System Colors Light"
        let (settings, directory) = try Self.settings(#"{"appearance":{"theme":"\#(theme)","background":"wheat-field-with-cypresses"}}"#)
        let saved = (GhosttyRuntime.themeOverride, GhosttyRuntime.fontOverride, GhosttyRuntime.backgroundOverride,
                     GhosttyRuntime.terminalBackgroundOverridden, DesignSettings.shared.terminalFontFamily)
        defer {
            settings.stop()
            try? FileManager.default.removeItem(at: directory)
            (GhosttyRuntime.themeOverride, GhosttyRuntime.fontOverride, GhosttyRuntime.backgroundOverride,
             GhosttyRuntime.terminalBackgroundOverridden, DesignSettings.shared.terminalFontFamily) = saved
        }
        settings.start()
        TerminalThemeSetting.prime(settings.snapshot)
        #expect(GhosttyRuntime.themeOverride == theme, "primed before the runtime loads its config")
        var reloads = 0
        let follower = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        follower.reload = { reloads += 1 }
        follower.follow(settings)
        #expect(reloads == 0)
        let unprimed = TerminalThemeSetting(backdropScope: ThemeScope(level: .room))
        unprimed.reload = { reloads += 1 }
        unprimed.follow(settings)
        #expect(reloads == 1, "the priming covers one launch")
    }
}
