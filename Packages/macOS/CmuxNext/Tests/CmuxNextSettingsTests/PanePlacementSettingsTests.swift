import CmuxNextDesign
import Foundation
import Testing
@testable import CmuxNextSettings

/// `layout.newPanePlacement` and `layout.tileBrowsers`: tabs by default,
/// browsers never tile unless asked, bad values fall back with a diagnostic.
@Suite struct PanePlacementSettingsTests {
    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsAreTabsAndNoBrowserTiling() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.newPanePlacement == .tab)
        #expect(snapshot.tileBrowsers == false)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func readsEveryChoice() throws {
        let snapshot = try parse(#"{"layout": {"newPanePlacement": "split", "tileBrowsers": true}}"#)
        #expect(snapshot.newPanePlacement == .split)
        #expect(snapshot.tileBrowsers)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidValuesUseTheDefaultsWithDiagnostics() throws {
        let snapshot = try parse(#"{"layout": {"newPanePlacement": "grid", "tileBrowsers": "yes"}}"#)
        #expect(snapshot.newPanePlacement == CmuxConfigSnapshot.newPanePlacementFallback)
        #expect(snapshot.tileBrowsers == CmuxConfigSnapshot.tileBrowsersFallback)
        #expect(Set(snapshot.diagnostics.map(\.path)) == ["layout.newPanePlacement", "layout.tileBrowsers"])
    }

    @Test func schemaDefaultsMatchTheParser() throws {
        let placement = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.newPanePlacementPath))
        #expect(placement.defaultValue == .string(CmuxConfigSnapshot.newPanePlacementFallback.rawValue))
        let tiles = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.tileBrowsersPath))
        #expect(tiles.defaultValue == .bool(CmuxConfigSnapshot.tileBrowsersFallback))
    }
}
