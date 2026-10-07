import CmuxNextSettings
import Foundation
import Testing

/// BACK-FORWARD-WORKSPACES-ONLY: `navigation.history.scope` is `workspaces`
/// by default, takes `everything`, reports a bad value, is in the schema
/// with that default, and agents may set it.
@Suite struct NavigationHistoryStepSettingTests {
    func parse(_ text: String) throws -> CmuxConfigSnapshot {
        CmuxConfigSnapshot.parse(try JSONC.parse(text), validDensities: [], validMetrics: [])
    }

    @Test func defaultsValuesAndDiagnostics() throws {
        #expect(try parse("{}").navigationHistorySteps == "workspaces")
        #expect(try parse(#"{"navigation": {"history": {"scope": "everything"}}}"#).navigationHistorySteps == "everything")
        let bad = try parse(#"{"navigation": {"history": {"scope": "tabs"}}}"#)
        #expect(bad.navigationHistorySteps == "workspaces")
        #expect(bad.diagnostics.map(\.path) == ["navigation.history.scope"])
        #expect(try parse(#"{"navigation": {"historyScope": "window", "history": {"scope": "everything"}}}"#).navigationHistoryScope == "window",
                "the older key still parses beside it")
    }

    @Test func theSchemaListsItAndAgentsMaySetIt() {
        #expect(SettingsSchema.descriptor(for: ["navigation", "history", "scope"])?.defaultValue == .string("workspaces"))
        #expect(SettingsSchema.agentSettableKeys.contains("navigation.history.scope"))
    }
}
