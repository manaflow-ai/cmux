import CmuxNextSettings
import Testing

/// `sidebar.showTimestamps` (Lawrence 2026-10-19: "By default in the sidebar, we should never show
/// timestamps, like how long something took"): off by default, the user turns it on in Settings,
/// cmux.json, `cmux settings set` or Cmd+Shift+P, and a bad value keeps the default with a diagnostic.
struct SidebarShowTimestampsSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["showTimestamps": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.showTimestamps == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).sidebarSections.showTimestamps)
        #expect(Self.parse(.bool(false)).sidebarSections.showTimestamps == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.sidebarSections.showTimestamps == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showTimestamps" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "showTimestamps"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
    }
}
