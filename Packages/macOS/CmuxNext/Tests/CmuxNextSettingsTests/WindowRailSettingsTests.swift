import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `window.rail`: "off" unless the file names a placement; a bad value keeps
/// "off" and reports a diagnostic; removing the key restores it.
@Suite struct WindowRailSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToOff() throws {
        #expect(try parse("{}").rail == .off)
        #expect(try parse("{}").diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.rail == .off)
    }

    @Test func readsEveryPlacement() throws {
        for placement in WindowRailPlacement.allCases {
            #expect(try parse(#"{"window": {"rail": "\#(placement.rawValue)"}}"#).rail == placement)
        }
        #expect(WindowRailPlacement.allCases.map(\.rawValue) == ["off", "leading", "afterSidebar"])
    }

    @Test func badValuesKeepOffWithADiagnostic() throws {
        for text in [#"{"window": {"rail": "trailing"}}"#, #"{"window": {"rail": true}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.rail == .off, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["window.rail"], "\(text)")
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"window": {"rail": "afterSidebar"}}"#))
        #expect(design.rail == .afterSidebar)
        applier.apply(try parse(#"{"window": {"rail": "leading", "titlebar": "standard"}}"#))
        #expect(design.rail == .leading)
        #expect(design.titlebar == .standard)
        applier.apply(try parse("{}"))
        #expect(design.rail == .off)
    }
}
