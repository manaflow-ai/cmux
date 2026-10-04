import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.rows` (plans/cmux-next/rows.md O1): on by default in the parser
/// and `DesignSettings`; a bad value keeps the default with a diagnostic.
@Suite struct RowsSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @MainActor @Test func defaultsOn() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.layoutRows && DesignSettings().layoutRows)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsOffAndRefusesANonBoolean() throws {
        #expect(try parse(#"{"layout": {"rows": false}}"#).layoutRows == false)
        let bad = try parse(#"{"layout": {"rows": "no"}}"#)
        #expect(bad.layoutRows)
        #expect(bad.diagnostics.map(\.path) == ["layout.rows"])
    }

    @MainActor @Test func appliesToDesignSettings() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"rows": false}}"#))
        #expect(design.layoutRows == false)
        applier.apply(try parse("{}"))
        #expect(design.layoutRows)
    }
}
