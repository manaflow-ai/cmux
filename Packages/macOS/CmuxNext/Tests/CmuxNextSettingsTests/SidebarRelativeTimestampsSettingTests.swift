import CmuxNextSettings
import Testing

/// `sidebar.relativeTimestamps`: with `sidebar.showTimestamps` on, a change today reads as its age (`2h`)
/// instead of its time. Off by default, so today's rows keep their time; a bad value keeps the default
/// with a diagnostic.
struct SidebarRelativeTimestampsSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["relativeTimestamps": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.relativeTimestamps == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).sidebarSections.relativeTimestamps)
        #expect(Self.parse(.bool(false)).sidebarSections.relativeTimestamps == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.sidebarSections.relativeTimestamps == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.relativeTimestamps" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "relativeTimestamps"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
    }
}
