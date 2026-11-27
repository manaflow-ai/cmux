import CmuxNextSettings
import Testing

/// `sidebar.showNewWorkspaceChooser`: the chevron beside the sidebar titlebar's + is off by default,
/// so a fresh sidebar is a plain linear list (Lawrence 2026-10-30, message 18548: "by default i dont
/// want to have workspace titlebar dropdowns at all"). The user turns it on in Settings, cmux.json,
/// `cmux settings set` or Cmd+Shift+P; a bad value keeps the default with a diagnostic.
struct SidebarShowNewWorkspaceChooserSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["showNewWorkspaceChooser": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.showNewWorkspaceChooser == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOn() {
        #expect(Self.parse(.bool(true)).sidebarSections.showNewWorkspaceChooser)
        #expect(Self.parse(.bool(false)).sidebarSections.showNewWorkspaceChooser == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.showNewWorkspaceChooser == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.showNewWorkspaceChooser" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "showNewWorkspaceChooser"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
    }
}
