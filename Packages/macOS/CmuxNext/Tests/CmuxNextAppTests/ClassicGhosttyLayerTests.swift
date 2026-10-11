@testable import CmuxNextTerminal
import Foundation
import Testing

/// The update from classic cmux (hq#1870 parity audit, P0 5): classic's
/// Settings wrote terminal settings (font, theme, cursor) to its cmux-only
/// Ghostty layer, `~/Library/Application Support/<classic bundle id>/`,
/// separate from the person's own Ghostty config. Next loads that layer
/// after the person's Ghostty files, as classic did.
struct ClassicGhosttyLayerTests {
    static func support(_ files: [String: String]) throws -> URL {
        let support = FileManager.default.temporaryDirectory.appending(path: "cn-classic-ghostty-\(UUID().uuidString)")
        for (path, text) in files {
            let url = support.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return support
    }

    @Test @MainActor func classicsTerminalSettingsApplyAfterTheUpdate() throws {
        // A stale legacy `config` beside a non-empty `config.ghostty` is not read, as in classic.
        let support = try Self.support(["com.cmuxterm.app/config.ghostty": "font-size = 17\n",
                                        "com.cmuxterm.app/config": "font-size = 9\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(GhosttyRuntime.defaultFilesFontSize(applicationSupportDirectory: support) == 17)
    }

    @Test @MainActor func aNightlyBuildFallsBackToStablesLayer() throws {
        let support = try Self.support(["com.cmuxterm.app/config": "font-size = 15\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(GhosttyRuntime.defaultFilesFontSize(applicationSupportDirectory: support,
                                                    bundleIdentifier: "com.cmuxterm.app.nightly") == 15)
    }

    @Test @MainActor func stableNeverReadsAnotherChannelsLayer() throws {
        // Classic's stable app had no fallback; an old nightly file must not recolor it.
        let support = try Self.support(["com.cmuxterm.app.nightly/config": "font-size = 15\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(GhosttyRuntime.defaultFilesFontSize(applicationSupportDirectory: support,
                                                    bundleIdentifier: "com.cmuxterm.app") != 15)
    }

    @Test @MainActor func thisChannelsLayerWins() throws {
        // Next nightly ships as classic nightly's bundle: its own layer, not stable's.
        let support = try Self.support(["com.cmuxterm.app/config.ghostty": "font-size = 17\n",
                                        "com.cmuxterm.app.nightly/config.ghostty": "font-size = 15\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        #expect(GhosttyRuntime.defaultFilesFontSize(applicationSupportDirectory: support,
                                                    bundleIdentifier: "com.cmuxterm.app.nightly") == 15)
    }
}
