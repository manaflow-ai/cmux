@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextPalette
import Foundation
import Testing

/// The daemon's palette usage history (`palette-usage-v1`) as the palette's
/// mirror: snapshots decode without computing a score,
/// and former per-build histories are found and turned into import rows.
@Suite struct PaletteUsageWireTests {
    static func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    let snapshot = try! Self.json("""
        {"revision": "4", "half_life_ms": "259200000", "pick_half_life_ms": "604800000",
         "entries": [{"key": "action:newColumn", "score": 2.5, "last_used_ms": "1800000000000"}],
         "picks": [
           {"prefix": "n", "key": "action:newColumn", "score": 2.0, "last_used_ms": "1800000000000", "last": true},
           {"prefix": "n", "key": "action:newWindow", "score": 1.0, "last_used_ms": "1799990000000", "last": false}],
         "imported": ["com.cmuxterm.app.debug.nxdog70.v1"]}
        """)

    @Test func aSnapshotBecomesTheMirror() throws {
        let (history, revision, imported) = try PaletteUsageWire.history(snapshot)
        #expect(revision == 4)
        #expect(imported == ["com.cmuxterm.app.debug.nxdog70.v1"])
        #expect(history.entries["action:newColumn"]?.score == 2.5)
        #expect(history.entries["action:newColumn"]?.lastUsed == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(history.halfLife == 259_200)
        #expect(history.pickHalfLife == 604_800)
        #expect(history.picks.map(\.key) == ["action:newColumn", "action:newWindow"])
        #expect(history.picks.map(\.isLast) == [true, false])
    }

    @Test func formerPerBuildHistoriesAreFoundAndBecomeImportRows() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("palette-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var former = FrecencyStore()
        former.record("action:newColumn", at: Date(timeIntervalSince1970: 1_700_000_000))
        former.record(" ", at: Date(timeIntervalSince1970: 1_700_000_000))
        let stored = try JSONEncoder().encode(former)
        func write(_ name: String, _ plist: [String: Any]) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: folder.appendingPathComponent(name))
        }
        try write("com.cmuxterm.app.debug.nxdog70.v1.plist", ["cmuxNext.palette.frecency.v1": stored])
        try write("com.cmuxterm.app.debug.other.plist", ["unrelated": 1])
        try write("com.apple.finder.plist", ["cmuxNext.palette.frecency.v1": stored])
        let found = PaletteUsageWire.legacyHistories(preferences: folder)
        #expect(found.map(\.source) == ["com.cmuxterm.app.debug.nxdog70.v1"])
        let rows = PaletteUsageWire.importRows(try #require(found.first).history)
        #expect(rows == [try Self.json(#"{"key": "action:newColumn", "score": 1, "last_used_ms": "1700000000000"}"#)],
                "a blank key is not sent")
    }
}
