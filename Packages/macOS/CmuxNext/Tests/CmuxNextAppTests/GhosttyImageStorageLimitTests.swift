import Foundation
import GhosttyNextKit
import Testing
@testable import CmuxNextTerminal

@MainActor
@Suite("Ghostty image storage limit", .serialized)
struct GhosttyImageStorageLimitTests {
    @Test func cmuxUsesABoundedViewerDefault() throws {
        #expect(try resolvedLimit("") == 5_000_000)
    }

    @Test func userConfigOverridesTheCmuxDefault() throws {
        #expect(try resolvedLimit("image-storage-limit = 1234567\n") == 1_234_567)
    }

    private func resolvedLimit(_ text: String) throws -> UInt32 {
        _ = GhosttyRuntime.shared // runs ghostty_init, which config_new needs
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-image-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        // The file goes in as an argument, never through setenv: a write after
        // ghostty_init frees the environ copy libghostty reads, and
        // ghostty_config_finalize then crashed this suite (signal 11).
        var diagnostics: [String] = []
        var opacity = 1.0
        let config = try #require(GhosttyRuntime.loadConfig(diagnostics: &diagnostics, opacity: &opacity,
                                                            configFile: file.path))
        defer { ghostty_config_free(config) }
        var value: UInt32 = 0
        #expect(GhosttyRuntime.configGet(config, &value, key: "image-storage-limit"))
        return value
    }
}
