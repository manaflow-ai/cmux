import CmuxNextSettings
import Testing

/// `tabs.verticalTabs` (Use Vertical Tabs for All Workspaces) is off by default: tabs stay a horizontal strip
/// (Leo 2026-10-20: "NOT a global default"). `tabs.verticalTabsExpandOnHover` is on by default. A bad value
/// keeps the default with a diagnostic, and Settings lists both toggles.
struct VerticalTabsSettingTests {
    static func parse(_ tabs: [String: JSONValue]) -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(.object(["tabs": .object(tabs)]), validDensities: [], validMetrics: [])
    }

    @Test func tabsStayHorizontalByDefault() {
        let snapshot = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(snapshot.verticalTabs == false)
        #expect(snapshot.verticalTabsExpandOnHover)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func thePersonCanMakeVerticalTabsTheDefault() {
        let snapshot = Self.parse(["verticalTabs": .bool(true), "verticalTabsExpandOnHover": .bool(false)])
        #expect(snapshot.verticalTabs)
        #expect(snapshot.verticalTabsExpandOnHover == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(["verticalTabs": .string("yes"), "verticalTabsExpandOnHover": .number(0)])
        #expect(snapshot.verticalTabs == false)
        #expect(snapshot.verticalTabsExpandOnHover)
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.verticalTabs" }, "\(snapshot.diagnostics)")
        #expect(snapshot.diagnostics.contains { $0.path == "tabs.verticalTabsExpandOnHover" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsBothToggles() throws {
        let all = try #require(SettingsSchema.descriptor(for: ["tabs", "verticalTabs"]))
        #expect(all.defaultValue == .bool(false))
        let hover = try #require(SettingsSchema.descriptor(for: ["tabs", "verticalTabsExpandOnHover"]))
        #expect(hover.defaultValue == .bool(true))
    }
}
