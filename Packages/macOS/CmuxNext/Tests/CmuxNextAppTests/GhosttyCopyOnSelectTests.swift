import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

/// Copy-on-select is the person's Ghostty setting: cmux NEXT adds no line for it, so it is off unless
/// their config turns it on, and `copy-on-select = false` turns it off again (classic's bug: cmux#21936).
@MainActor
@Suite("Ghostty copy-on-select", .serialized)
struct GhosttyCopyOnSelectTests {
    @Test func offByDefault() throws {
        #expect(try resolved("") == "none")
    }

    @Test func userConfigTurnsItOnAndOff() throws {
        #expect(try resolved("copy-on-select = true\n") == "clipboard")
        #expect(try resolved("copy-on-select = false\n") == "none")
        #expect(try resolved("copy-on-select = true\ncopy-on-select = false\n") == "none")
    }

    private func resolved(_ text: String) throws -> String? {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-copy-on-select-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        // The file goes in as an argument, never through setenv (GhosttyImageStorageLimitTests).
        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity,
                                                            configFile: file.path))
        defer { ghostty_config_free(config) }
        var name: UnsafePointer<CChar>?
        let key = "copy-on-select"
        let found = withUnsafeMutablePointer(to: &name) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
        return found ? name.map { String(cString: $0) } : nil
    }
}
