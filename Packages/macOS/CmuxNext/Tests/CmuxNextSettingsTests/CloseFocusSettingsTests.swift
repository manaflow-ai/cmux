import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.closeFocus`: "previousNeighbor" (REWRITE.md round 5, close-focus.md)
/// unless the file says "mostRecent"; a bad value keeps the default with a
/// diagnostic.
@Suite struct CloseFocusSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToThePreviousNeighborAsTheDocSays() throws {
        #expect(try parse("{}").closeFocus == .previousNeighbor)
        #expect(CloseFocusSetting.fallback == .previousNeighbor)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsBothPolicies() throws {
        #expect(try parse(#"{"layout": {"closeFocus": "mostRecent"}}"#).closeFocus == .mostRecent)
        #expect(try parse(#"{"layout": {"closeFocus": "previousNeighbor"}}"#).closeFocus == .previousNeighbor)
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"layout": {"closeFocus": "random"}}"#)
        #expect(snapshot.closeFocus == .previousNeighbor)
        #expect(snapshot.diagnostics.map(\.path) == ["layout.closeFocus"])
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"closeFocus": "mostRecent"}}"#))
        #expect(design.closeFocus == .mostRecent)
        applier.apply(try parse("{}"))
        #expect(design.closeFocus == .previousNeighbor)
    }
}
