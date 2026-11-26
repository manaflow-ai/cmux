import Foundation
import Testing
@testable import CmuxNextDaemon

struct PaletteUsageLegacyHistoryTests {
    @Test func readsOnlyUnimportedCmuxDomainsFromTheSelectedPreferences() async throws {
        let preferences = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: preferences) }
        let history = Data(#"{"entries":{"action":{"score":1.0,"lastUsed":5.0}}}"#.utf8)
        let data = try PropertyListSerialization.data(fromPropertyList: ["cmuxNext.palette.frecency.v1": history], format: .binary, options: 0)
        for domain in ["com.cmuxterm.app", "com.cmuxterm.app.debug.dogfood", "com.example.unrelated"] {
            try data.write(to: preferences.appendingPathComponent(domain + ".plist"))
        }

        let empty = "com.cmuxterm.app.rc"
        let emptyPlist = try PropertyListSerialization.data(fromPropertyList: ["other": true], format: .binary, options: 0)
        try emptyPlist.write(to: preferences.appendingPathComponent(empty + ".plist"))
        let sources = await PaletteUsageLegacyHistory.read(preferences: preferences, excluding: ["com.cmuxterm.app"])
        #expect(sources.map(\.source) == ["com.cmuxterm.app.debug.dogfood", empty])
        #expect(sources.first?.rows.count == 1)
        #expect(sources.last?.rows.isEmpty == true)
    }
}
