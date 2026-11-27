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

    @Test @MainActor func onlyTheImportedCopyChangesTheTerminal() throws {
        let root = try Self.support(["com.cmuxterm.app/config.ghostty": "font-size = 79\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let layer = root.appending(path: "next/classic-ghostty/config.ghostty")
        #expect(GhosttyRuntime.defaultFilesFontSize(importedLayer: layer) != 79)
        try FileManager.default.createDirectory(at: layer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("font-size = 79\n".utf8).write(to: layer)
        #expect(GhosttyRuntime.defaultFilesFontSize(importedLayer: layer) == 79)
    }
}
