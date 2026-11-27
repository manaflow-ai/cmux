import CmuxNextSettings
import Testing

/// `sidebar.detailedStatusIcons`: off by default (rows say Working or Ready), the user turns it on,
/// Settings lists the toggle, and a bad value keeps the default with a diagnostic.
struct SidebarDetailedStatusIconsSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["detailedStatusIcons": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.detailedStatusIcons == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).sidebarSections.detailedStatusIcons)
        #expect(Self.parse(.bool(false)).sidebarSections.detailedStatusIcons == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.sidebarSections.detailedStatusIcons == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.detailedStatusIcons" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "detailedStatusIcons"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
    }
}
