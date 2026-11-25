import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Leo's sidebar prototypes as first-class toggles (2026-10-21: "They're just toggles in the app
/// store area"): `sidebar.workspacesAsTabs`, `sidebar.chromeGroups` and `sidebar.sideBySide` are
/// schema settings, so the App Store cards, Settings, the palette and `cmux settings` all reach them
/// in every build. Each is off by default; a bad value keeps the default with a diagnostic.
struct SidebarPrototypeTogglesSettingTests {
    static let keys = ["workspacesAsTabs", "chromeGroups", "sideBySide"]

    static func parse(_ key: String, _ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object([key: $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    static func flag(_ key: String, _ preferences: SidebarSectionsPreferences) -> Bool {
        switch key {
        case "workspacesAsTabs": preferences.workspacesAsTabs
        case "chromeGroups": preferences.chromeGroups
        default: preferences.sideBySide
        }
    }

    @Test(arguments: keys) func offByDefault(_ key: String) {
        let snapshot = Self.parse(key, nil)
        #expect(!Self.flag(key, snapshot.sidebarSections))
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test(arguments: keys) func theUserCanTurnItOn(_ key: String) {
        #expect(Self.flag(key, Self.parse(key, .bool(true)).sidebarSections))
        #expect(!Self.flag(key, Self.parse(key, .bool(false)).sidebarSections))
    }

    @Test(arguments: keys) func aBadValueKeepsTheDefaultWithADiagnostic(_ key: String) {
        let snapshot = Self.parse(key, .string("yes"))
        #expect(!Self.flag(key, snapshot.sidebarSections))
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.\(key)" }, "\(snapshot.diagnostics)")
    }

    @Test(arguments: keys) func settingsAndThePaletteListTheToggle(_ key: String) throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", key]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed)
    }
}
