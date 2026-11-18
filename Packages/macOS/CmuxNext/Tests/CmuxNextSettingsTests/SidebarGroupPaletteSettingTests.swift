import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.groupPalette`: where group colors come from and whether a new group takes the palette's next color. Pure
/// glass by default, so a new user's groups get no color they didn't choose; the group editor's marbles, Settings,
/// Cmd+Shift+P, the CLI and MCP set it, and a bad value keeps glass with a diagnostic.
struct SidebarGroupPaletteSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["groupPalette": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func glassByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.groupPalette == .glass)
        #expect(snapshot.diagnostics.isEmpty, "no key, no diagnostic: \(snapshot.diagnostics)")
    }

    @Test(arguments: GroupPalette.allCases)
    func everyPaletteParses(_ palette: GroupPalette) {
        #expect(Self.parse(.string(palette.rawValue)).sidebarSections.groupPalette == palette)
    }

    @Test func aBadValueKeepsGlassWithADiagnostic() {
        let snapshot = Self.parse(.string("rainbow"))
        #expect(snapshot.sidebarSections.groupPalette == .glass)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.groupPalette" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsAndThePaletteListEveryChoice() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "groupPalette"]))
        #expect(descriptor.defaultValue == .string("glass"))
        #expect(descriptor.section == .appearance)
        #expect(descriptor.isPaletteExposed, "Cmd+Shift+P lists every palette-exposed schema setting")
        guard case let .choice(choices) = descriptor.kind else { Issue.record("not a choice: \(descriptor.kind)"); return }
        #expect(choices.map(\.value) == GroupPalette.allCases.map(\.rawValue))
    }
}
