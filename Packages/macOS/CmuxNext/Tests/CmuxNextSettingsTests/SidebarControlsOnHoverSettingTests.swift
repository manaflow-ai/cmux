import CmuxNextSettings
import Testing

/// `sidebar.controlsOnHover` (Show Sidebar Controls Only on Hover, Lawrence 2026-10-27): the sidebar's controls hide until
/// the pointer is over it. Off by default, so the controls always show; a bad value keeps the default
/// with a diagnostic, and Settings and Cmd+Shift+P list the toggle.
struct SidebarControlsOnHoverSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["controlsOnHover": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.controlsOnHover == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOnAndOffAgain() {
        #expect(Self.parse(.bool(true)).sidebarSections.controlsOnHover)
        #expect(Self.parse(.bool(false)).sidebarSections.controlsOnHover == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.controlsOnHover == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.controlsOnHover" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "controlsOnHover"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
    }
}
