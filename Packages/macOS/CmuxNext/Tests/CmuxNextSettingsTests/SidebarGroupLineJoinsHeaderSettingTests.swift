import CmuxNextSettings
import Testing

/// `sidebar.groupLineJoinsHeader` (Leo 2026-10-19): off by default (the members' line starts a
/// small cut below the group header, as Chrome's tab groups do), the user turns it on to join
/// them, Settings lists the toggle, an agent may set it, and a bad value keeps the default with a
/// diagnostic.
struct SidebarGroupLineJoinsHeaderSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["groupLineJoinsHeader": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.groupLineJoinsHeader == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).sidebarSections.groupLineJoinsHeader)
        #expect(Self.parse(.bool(false)).sidebarSections.groupLineJoinsHeader == false)
    }

    @Test func aBadValueKeepsTheDefaultAndSaysWhy() {
        let snapshot = Self.parse(.string("on"))
        #expect(snapshot.sidebarSections.groupLineJoinsHeader == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.groupLineJoinsHeader" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListsTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "groupLineJoinsHeader"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
    }
}
