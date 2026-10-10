@testable import CmuxNextDaemon
import Foundation
import Testing

/// The former per-build palette histories (UserDefaults domains of each
/// dogfood tag) become `palette_usage.import` rows off the main actor, in
/// the daemon client module: only cmux domains with a history, only rows the
/// catalog accepts.
@Suite struct PaletteUsageLegacyHistoryTests {
    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    @Test func formerHistoriesAreReadOffTheMainActorAndBecomeImportRows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("palette-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // The former FrecencyStore JSON: dates as seconds since the reference date.
        let stored = Data(#"""
            {"entries": {"action:newColumn": {"score": 2.5, "lastUsed": 800000000},
                         " ": {"score": 1, "lastUsed": 800000000},
                         "action:nan": {"score": -1, "lastUsed": 800000000}},
             "halfLife": 259200, "capacity": 500}
            """#.utf8)
        func write(_ name: String, _ plist: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: folder.appendingPathComponent(name))
        }
        try write("com.cmuxterm.app.debug.nxdog70.v1.plist", ["cmuxNext.palette.frecency.v1": stored])
        try write("com.cmuxterm.app.debug.other.plist", ["unrelated": 1])
        try write("com.apple.finder.plist", ["cmuxNext.palette.frecency.v1": stored])
        let found = await PaletteUsageLegacyHistory.read(preferences: folder)
        #expect(found.map(\.source) == ["com.cmuxterm.app.debug.nxdog70.v1"])
        let lastUsedMs = String(UInt64((800_000_000 + Date.timeIntervalBetween1970AndReferenceDate) * 1000))
        #expect(found.first?.rows == [try Self.json(#"{"key": "action:newColumn", "score": 2.5, "last_used_ms": "\#(lastUsedMs)"}"#)])
    }
}
