import Foundation
import Testing
@testable import CmuxNextSettings

/// `workspaces.newPlacement`: new workspaces go to the top by default
/// (Lawrence 2026-10-08, cx-plf5); `afterCurrent` and `bottom` are the other
/// choices; a bad value falls back with a diagnostic.
@Suite struct NewWorkspacePlacementSettingTests {
    @Test func groupByComputerIsOffByDefaultAndReadsAFlag() throws {
        #expect(try parse("{}").sidebarSections.groupsByComputer == false)
        #expect(try parse(#"{"sidebar": {"groupByComputer": true}}"#).sidebarSections.groupsByComputer)
        let bad = try parse(#"{"sidebar": {"groupByComputer": "yes"}}"#)
        #expect(bad.sidebarSections.groupsByComputer == false)
        #expect(bad.diagnostics.map(\.path) == ["sidebar.groupByComputer"])
        #expect(SettingsSchema.agentSettableKeys.contains("sidebar.groupByComputer"))
    }

    private func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultIsTop() throws {
        let snapshot = try parse("{}")
        #expect(snapshot.newWorkspacePlacement == .top)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test(arguments: NewWorkspacePlacement.allCases)
    func readsEveryChoice(_ placement: NewWorkspacePlacement) throws {
        let snapshot = try parse(#"{"workspaces": {"newPlacement": "\#(placement.rawValue)"}}"#)
        #expect(snapshot.newWorkspacePlacement == placement)
        #expect(snapshot.diagnostics.isEmpty)
    }

    @Test func invalidValueUsesTheDefaultWithADiagnostic() throws {
        let snapshot = try parse(#"{"workspaces": {"newPlacement": "middle"}}"#)
        #expect(snapshot.newWorkspacePlacement == .top)
        #expect(snapshot.diagnostics.map(\.path) == ["workspaces.newPlacement"])
    }

    @Test func schemaRowMatchesTheParser() throws {
        let row = try #require(SettingsSchema.descriptor(for: CmuxConfigSnapshot.newWorkspacePlacementPath))
        #expect(row.defaultValue == .string(NewWorkspacePlacement.top.rawValue))
        #expect(SettingsSchema.agentSettableKeys.contains("workspaces.newPlacement"))
    }
}
