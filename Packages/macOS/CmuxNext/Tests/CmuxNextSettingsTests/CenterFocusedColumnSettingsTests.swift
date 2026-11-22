import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.centerFocusedColumn`: "never" unless the file says "always" or
/// "on-overflow"; a bad value keeps "never" with a diagnostic.
@Suite struct CenterFocusedColumnSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToNever() throws {
        #expect(try parse("{}").centerFocusedColumn == .never)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsEveryMode() throws {
        #expect(try parse(#"{"layout": {"centerFocusedColumn": "always"}}"#).centerFocusedColumn == .always)
        #expect(try parse(#"{"layout": {"centerFocusedColumn": "on-overflow"}}"#).centerFocusedColumn == .onOverflow)
        #expect(try parse(#"{"layout": {"centerFocusedColumn": "never"}}"#).centerFocusedColumn == .never)
    }

    @Test func badValuesKeepNeverWithADiagnostic() throws {
        let snapshot = try parse(#"{"layout": {"centerFocusedColumn": "middle"}}"#)
        #expect(snapshot.centerFocusedColumn == .never)
        #expect(snapshot.diagnostics.map(\.path) == ["layout.centerFocusedColumn"])
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"centerFocusedColumn": "always"}}"#))
        #expect(design.centerFocusedColumn == .always)
        applier.apply(try parse("{}"))
        #expect(design.centerFocusedColumn == .never)
    }
}
