import CmuxNextSettings
import Testing

/// `sidebar.noFade`: the left sidebar shows its whole list with no edge fade and hides the
/// bottom profile and search bar. Off by default; the user turns it on from Cmd+Shift+P or cmux.json,
/// and a bad value keeps the default with a diagnostic.
struct SidebarNoFadeSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["noFade": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func offByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.noFade == false)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test func theUserCanTurnItOnAndOffAgain() {
        #expect(Self.parse(.bool(true)).sidebarSections.noFade)
        #expect(Self.parse(.bool(false)).sidebarSections.noFade == false)
    }

    @Test func aBadValueKeepsTheDefaultWithADiagnostic() {
        let snapshot = Self.parse(.string("yes"))
        #expect(snapshot.sidebarSections.noFade == false)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.noFade" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListTheToggleOffByDefault() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "noFade"]))
        #expect(descriptor.defaultValue == .bool(false))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
    }
}
