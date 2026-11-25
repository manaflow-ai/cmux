import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `sidebar.groupGradient`: the gradient the gradient palette steps through (Leo 2026-11-07: "you could have, like, a
/// gradients option"). Sunset by default; Settings, Cmd+Shift+P, the CLI and MCP set it; a bad value keeps Sunset with
/// a diagnostic.
struct SidebarGroupGradientSettingTests {
    static func parse(_ value: JSONValue?) -> CmuxConfigSnapshot {
        let root: JSONValue = value.map { .object(["sidebar": .object(["groupGradient": $0])]) } ?? .object([:])
        return CmuxConfigSnapshot.parse(root, validDensities: [], validMetrics: [])
    }

    @Test func sunsetByDefault() {
        let snapshot = Self.parse(nil)
        #expect(snapshot.sidebarSections.groupGradient == .sunset)
        #expect(snapshot.diagnostics.isEmpty, "\(snapshot.diagnostics)")
    }

    @Test(arguments: GroupGradient.allCases)
    func everyGradientParses(_ gradient: GroupGradient) {
        #expect(Self.parse(.string(gradient.rawValue)).sidebarSections.groupGradient == gradient)
    }

    @Test func aBadValueKeepsSunsetWithADiagnostic() {
        let snapshot = Self.parse(.string("plaid"))
        #expect(snapshot.sidebarSections.groupGradient == .sunset)
        #expect(snapshot.diagnostics.contains { $0.path == "sidebar.groupGradient" }, "\(snapshot.diagnostics)")
    }

    @Test func settingsListEveryGradientAndThePaletteListsGradient() throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: ["sidebar", "groupGradient"]))
        #expect(descriptor.defaultValue == .string("sunset"))
        #expect(descriptor.isPaletteExposed)
        guard case let .choice(choices) = descriptor.kind else { Issue.record("not a choice: \(descriptor.kind)"); return }
        #expect(choices.map(\.value) == GroupGradient.allCases.map(\.rawValue))
        let palette = try #require(SettingsSchema.descriptor(for: ["sidebar", "groupPalette"]))
        guard case let .choice(palettes) = palette.kind else { Issue.record("not a choice"); return }
        #expect(palettes.map(\.value).contains("gradient"))
    }
}
