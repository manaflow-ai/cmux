import CmuxNextActions
import CmuxNextDesign
import CmuxNextSettings
import Foundation
import Testing

/// `window.rail`: "leading" (the rail at the window's leading edge, the
/// sidebar beside it, Leo 2026-10-03) unless the file names a placement; a
/// bad value keeps "leading" and reports a diagnostic; removing the key
/// restores it. The schema, the MDM manifest and a fresh `DesignSettings`
/// carry the same default.
@Suite struct WindowRailSettingsTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsToTheLeadingEdge() throws {
        #expect(try parse("{}").rail == .leading)
        #expect(try parse("{}").diagnostics.isEmpty)
        #expect(CmuxConfigSnapshot.empty.rail == .leading)
        #expect(WindowRailSetting.fallback == .leading)
    }

    /// Settings, the published schema and the MDM files show the same
    /// default, and a window opened before cmux.json loads already has the
    /// rail.
    @MainActor @Test func theSchemaTheManagedManifestAndDesignSettingsAgree() throws {
        let descriptor = try #require(SettingsSchema.all.first { $0.id == "window.rail" })
        #expect(descriptor.defaultValue == .string("leading"))
        let entry = try #require(ManagedPreferencesManifest.entries.first { $0.name == "window.rail" })
        #expect(entry.defaultValue == .string("leading"))
        #expect(entry.choices == ["off", "leading", "afterSidebar"])
        #expect(DesignSettings().rail == .leading)
    }

    @Test func readsEveryPlacement() throws {
        for placement in WindowRailPlacement.allCases {
            #expect(try parse(#"{"window": {"rail": "\#(placement.rawValue)"}}"#).rail == placement)
        }
        #expect(WindowRailPlacement.allCases.map(\.rawValue) == ["off", "leading", "afterSidebar"])
    }

    @Test func badValuesKeepTheDefaultWithADiagnostic() throws {
        for text in [#"{"window": {"rail": "trailing"}}"#, #"{"window": {"rail": true}}"#] {
            let snapshot = try parse(text)
            #expect(snapshot.rail == .leading, "\(text)")
            #expect(snapshot.diagnostics.map(\.path) == ["window.rail"], "\(text)")
        }
    }

    @MainActor @Test func appliesToDesignSettingsAndRevertsWhenRemoved() throws {
        let design = DesignSettings()
        let applier = SettingsApplier(design: design, registry: ActionRegistry.standard())
        applier.apply(try parse(#"{"window": {"rail": "afterSidebar"}}"#))
        #expect(design.rail == .afterSidebar)
        applier.apply(try parse(#"{"window": {"rail": "off", "titlebar": "standard"}}"#))
        #expect(design.rail == .off)
        #expect(design.titlebar == .standard)
        applier.apply(try parse("{}"))
        #expect(design.rail == .leading)
    }
}
