import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// R109: `sidebar.side` (left or right) and `sidebar.spacesPosition` (top
/// or bottom) are schema choices, so Settings and the palette list them.
@MainActor @Suite struct ChromePlacementSettingTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: ["compact"], validMetrics: [])
    }

    @Test func parsesBothKeysWithDefaultsAndDiagnostics() throws {
        let empty = try parse("{}")
        #expect(empty.sidebarSide == .left && empty.spacesPosition == .bottom)
        let set = try parse(#"{"sidebar": {"side": "right", "spacesPosition": "top"}}"#)
        #expect(set.sidebarSide == .right && set.spacesPosition == .top)
        let bad = try parse(#"{"sidebar": {"side": "up", "spacesPosition": 3}}"#)
        #expect(bad.sidebarSide == .left && bad.spacesPosition == .bottom)
        #expect(bad.diagnostics.map(\.path).sorted() == ["sidebar.side", "sidebar.spacesPosition"])
    }

    @Test(arguments: [(["sidebar", "side"], ["left", "right"], "left"),
                      (["sidebar", "spacesPosition"], ["top", "bottom"], "bottom"),
                      (["sidebar", "spacesVisibility"], ["hover", "always"], "hover")])
    func isASchemaChoiceForSettingsAndThePalette(_ path: [String], _ values: [String], _ fallback: String) throws {
        let descriptor = try #require(SettingsSchema.descriptor(for: path))
        guard case .choice(let choices) = descriptor.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(choices.map(\.value) == values)
        #expect(descriptor.defaultValue == .string(fallback))
        #expect(descriptor.isPaletteExposed)
        #expect(SettingsSchema.agentSettableKeys.contains(path.joined(separator: ".")))
    }

    @Test func theApplierSetsTheDesignSettings() throws {
        let design = DesignSettings()
        let snapshot = try parse(#"{"sidebar": {"side": "right", "spacesPosition": "top"}}"#)
        SettingsApplier.applyPlacement(snapshot, to: design)
        #expect(design.sidebarSide == .right && design.spacesPosition == .top)
    }

    /// cx-5k3r: `sidebar.spacesVisibility` is "hover" unless set; a bad
    /// value falls back with a diagnostic; the applier copies it.
    @Test func spacesVisibilityParsesAndApplies() throws {
        #expect(try parse("{}").spacesVisibility == .hover)
        let always = try parse(#"{"sidebar": {"spacesVisibility": "always"}}"#)
        #expect(always.spacesVisibility == .always)
        let bad = try parse(#"{"sidebar": {"spacesVisibility": "sometimes"}}"#)
        #expect(bad.spacesVisibility == .hover && bad.diagnostics.map(\.path) == ["sidebar.spacesVisibility"])
        let design = DesignSettings()
        SettingsApplier.applyPlacement(always, to: design)
        #expect(design.spacesVisibility == .always)
    }
}
