import CmuxNextSettings
import Testing

/// `sidebar.showSearchButton` (plans/cmux-next/sidebar-search.md): the sidebar footer's Search button
/// shows by default; the user hides it in Settings, cmux.json, `cmux settings set` or Cmd+Shift+P, and
/// a bad value keeps the default with a diagnostic.
struct SidebarShowSearchButtonSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["showSearchButton": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func onByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.showSearchButton)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOff() {
        #expect(Self.parse(.bool(false)).sidebarSections.showSearchButton == false)
        #expect(Self.parse(.bool(true)).sidebarSections.showSearchButton)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showSearchButton)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showSearchButton" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListTheToggleOnByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "showSearchButton"]))
        #expect(descriptor.defaultValue == .bool(true))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
    }
}
