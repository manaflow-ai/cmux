import CmuxNextSettings
import Testing

/// `screenshots.*`: the Screenshots pane finds screenshot apps unless turned off, and lists more
/// folders (absolute or ~/ paths); bad values keep the defaults and say why.
struct ScreenshotsSettingsTests {
    private static func parse(_ members: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["screenshots": .object(members)]), validDensities: [], validMetrics: [])
    }

    @Test func findsAppsAndAddsNoFoldersWhenUnset() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.screenshots == ScreenshotsSettings())
        #expect(snapshot.screenshots.findTools)
        #expect(snapshot.screenshots.folders.isEmpty)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsTheToggleAndTheFolders() {
        let snapshot = Self.parse(["findTools": .bool(false), "folders": .array([.string("/Users/ada/Shots"), .string("~/Pictures/Caps")])])
        #expect(!snapshot.screenshots.findTools)
        #expect(snapshot.screenshots.folders.first == "/Users/ada/Shots")
        #expect(snapshot.screenshots.folders.last?.hasSuffix("/Pictures/Caps") == true)
        #expect(snapshot.screenshots.folders.last?.hasPrefix("/") == true)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func badValuesKeepTheDefaultsAndSayWhy() {
        let snapshot = Self.parse(["findTools": .string("yes"), "folders": .array([.string("relative"), .string("/ok")])])
        #expect(snapshot.screenshots.findTools)
        #expect(snapshot.screenshots.folders == ["/ok"])
        #expect(snapshot.diagnostics.contains { $0.path == "screenshots.findTools" })
        #expect(snapshot.diagnostics.contains { $0.path == "screenshots.folders" })
    }

    @Test func bothRowsAreInSettings() throws {
        let toggle = try #require(SettingsSchema.descriptor(for: ["screenshots", "findTools"]))
        let folders = try #require(SettingsSchema.descriptor(for: ["screenshots", "folders"]))
        #expect(toggle.kind == .toggle)
        #expect(folders.kind == .folderList)
    }
}
