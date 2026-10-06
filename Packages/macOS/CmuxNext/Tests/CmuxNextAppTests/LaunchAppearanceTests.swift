import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// The first window draws in cmux.json's appearance: the file's theme and
/// background apply before launch goes on, never a frame of the defaults
/// first (sweep 4a: one dark frame without art before a light theme).
@MainActor
@Suite struct LaunchAppearanceTests {
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
}
