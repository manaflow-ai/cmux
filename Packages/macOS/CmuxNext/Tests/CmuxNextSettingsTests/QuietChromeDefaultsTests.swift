import CmuxNextSettings
import Testing

/// Chrome that is off until the person turns it on (Lawrence 2026-11-20: "drastically simplify all
/// parts of the UI"): the sidebar's daily tip card, the update feature tips and the Customize Menu…
/// row at the end of every right-click menu. Each is still one switch away in Settings, the palette,
/// `cmux settings set` and cmux.json.
struct QuietChromeDefaultsTests {
    static func parse(_ root: JSONValue) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test(arguments: [["sidebar", "cards", "tips"], ["updates", "showFeatureTips"], ["contextMenus", "showCustomizeItem"]])
    func offByDefault(_ path: [String]) throws {
        let row = try #require(SettingsSchema.descriptor(for: path))
        #expect(row.defaultValue == .bool(false), "\(path.joined(separator: ".")) is off until the person turns it on")
    }

    @Test func noTipCardUntilTurnedOn() {
        #expect(Self.parse(.object([:])).sidebarSections.showsTips == false)
        #expect(Self.parse(["sidebar": ["cards": ["tips": true]]]).sidebarSections.showsTips)
    }
}
