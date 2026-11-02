import CmuxNextSettings
import Testing

/// `browser.import.enabled`: on by default, so cmux keeps offering Import from Browser; Settings lists
/// the toggle in Browser, and a bad value keeps the default with a diagnostic.
struct BrowserImportSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["browser": .object(["import": .object(["enabled": $0])])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.browserImportEnabled)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOff() {
        #expect(Self.parse(.bool(false)).browserImportEnabled == false)
        #expect(Self.parse(.bool(true)).browserImportEnabled)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("no"))
        #expect(snapshot.browserImportEnabled)
        #expect(snapshot.diagnostics.contains { $0.path == "browser.import.enabled" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOnInBrowser() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["browser", "import", "enabled"]))
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.section == .browser)
    }
}
