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
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-image-limit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config")
        try Data(text.utf8).write(to: file)

        let built = try #require(GhosttyConfigInputs.testing(configFile: file.path).buildConfig())
        defer { built.free() }
        let config = try #require(built.config)
        var value: UInt32 = 0
        #expect(GhosttyRuntime.configGet(config, &value, key: "image-storage-limit"))
        return value
    }
}
