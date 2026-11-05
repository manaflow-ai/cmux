import CmuxNextDesign
import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// A new install's window is Glass (Leo, 2026-11-05: "new install should default to glass"), but a
/// value someone wrote in their Ghostty config is a choice, not a default: `background-opacity = 1`
/// stays opaque (`GhosttyRuntime+GlassDefault.swift`).
@MainActor
@Suite("Ghostty window glass default", .serialized)
struct GhosttyWindowGlassDefaultTests {
    @Test func aConfigThatWritesNeitherKeyIsTheGlassWindow() throws {
        let loaded = try load("")
        #expect(loaded.opacity == WindowBackgroundOverride.defaultTranslucentOpacity)
        #expect(loaded.blur == -1)
    }

    @Test func aWrittenFullOpacityStaysOpaque() throws {
        let loaded = try load("background-opacity = 1\n")
        #expect(loaded.opacity == 1)
        #expect(loaded.blur == 0)
    }

    @Test func aWrittenNoBlurStaysOpaque() throws {
        let loaded = try load("background-blur = false\n")
        #expect(loaded.opacity == 1)
        #expect(loaded.blur == 0)
    }

    @Test func writtenValuesAreKeptAndTheOtherKeyIsGhosttysDefault() throws {
        let opacityOnly = try load("background-opacity = 0.9\n")
        #expect(abs(opacityOnly.opacity - 0.9) < 1e-9)
        #expect(opacityOnly.blur == 0)
        let blurOnly = try load("background-blur = 20\n")
        #expect(blurOnly.opacity == 1)
        #expect(blurOnly.blur == 20)
        let both = try load("background-opacity = 0.7\nbackground-blur = macos-glass-clear\n")
        #expect(abs(both.opacity - 0.7) < 1e-9)
        #expect(both.blur == -2)
    }

    @Test func theLoadRecordsTheDefaultAsTheConfigsOwnValues() throws {
        _ = try load("")
        #expect(GhosttyConfigBackground.loaded.opacity == WindowBackgroundOverride.defaultTranslucentOpacity)
        #expect(GhosttyConfigBackground.loaded.blur == -1)
    }

    /// The loaded config's own `background-opacity` and `background-blur`, with no cmux.json override.
    private func load(_ text: String) throws -> (opacity: Double, blur: Int16) {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-glass-default-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        let saved = GhosttyRuntime.backgroundOverride
        GhosttyRuntime.backgroundOverride = WindowBackgroundOverride()
        defer { GhosttyRuntime.backgroundOverride = saved }
        // The file goes in as an argument, never through setenv (GhosttyImageStorageLimitTests).
        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity,
                                                            configFile: file.path))
        defer { ghostty_config_free(config) }
        var configured = 0.0
        #expect(GhosttyRuntime.configGet(config, &configured, key: "background-opacity"))
        var blur: Int16 = 0
        #expect(GhosttyRuntime.configGet(config, &blur, key: "background-blur"))
        return (configured, blur)
    }
}
