import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// `layout.defaultColumnWidth`: a proportion of the viewport, 0.1 to 1.0,
/// 0.5 when unset (niri `default-column-width { proportion 0.5; }`).
@Suite struct DefaultColumnWidthSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToHalf() throws {
        #expect(try parse("{}").defaultColumnWidth == 0.5)
        #expect(try parse("{}").diagnostics.isEmpty)
    }

    @Test func readsAProportion() throws {
        #expect(try parse(#"{"layout": {"defaultColumnWidth": 0.6667}}"#).defaultColumnWidth == 0.6667)
        #expect(try parse(#"{"layout": {"defaultColumnWidth": 1}}"#).defaultColumnWidth == 1.0)
        #expect(try parse(#"{"layout": {"defaultColumnWidth": 0.1}}"#).defaultColumnWidth == 0.1)
    }

    @Test func badValuesKeepHalfWithADiagnostic() throws {
        for bad in [#""half""#, "0", "1.5", "800", #"{"fixed": 800}"#] {
            let snapshot = try parse(#"{"layout": {"defaultColumnWidth": \#(bad)}}"#)
            #expect(snapshot.defaultColumnWidth == 0.5)
            #expect(snapshot.diagnostics.map(\.path) == ["layout.defaultColumnWidth"])
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"layout": {"defaultColumnWidth": 0.4}}"#))
        #expect(design.defaultColumnWidth == 0.4)
        applier.apply(try parse("{}"))
        #expect(design.defaultColumnWidth == 0.5)
    }
}
